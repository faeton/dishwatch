// Package dish talks to a local Starlink dish over its gRPC API.
//
// The dish exposes SpaceX.API.Device.Device/Handle, a single Request→Response
// method where the request is a oneof of get_status / get_history / etc. We
// discover the service schema via gRPC reflection at runtime (same trick that
// `grpcurl` uses) so we don't have to vendor .proto files.
//
// This client deliberately avoids `protoreflect/v2`'s heavy `grpcdynamic` /
// `desc` machinery — we talk to the reflection RPC directly, parse the raw
// FileDescriptorProto bytes with core protobuf, and invoke the method through
// `grpc.ClientConn.Invoke` with `*dynamicpb.Message`. That shaves ~2–3 MB
// off the binary versus using protoreflect/v2.
package dish

import (
	"context"
	"fmt"
	"io"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	refpb "google.golang.org/grpc/reflection/grpc_reflection_v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

const (
	defaultAddr   = "192.168.100.1:9200"
	serviceName   = "SpaceX.API.Device.Device"
	methodName    = "Handle"
	methodPath    = "/" + serviceName + "/" + methodName
	defaultDialMS = 2000
	defaultCallMS = 4000
)

// Client is a reflection-backed gRPC client for the dish.
type Client struct {
	addr   string
	conn   *grpc.ClientConn
	reqMD  protoreflect.MessageDescriptor
	respMD protoreflect.MessageDescriptor
}

// New dials the dish at addr (or $STARLINK_DISH, or the default) and resolves
// the Handle method via reflection.
func New(ctx context.Context, addr string) (*Client, error) {
	if addr == "" {
		addr = defaultAddr
	}
	dialCtx, cancel := context.WithTimeout(ctx, defaultDialMS*time.Millisecond)
	defer cancel()
	conn, err := grpc.DialContext(dialCtx, addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", addr, err)
	}

	files, err := resolveFiles(ctx, conn, serviceName)
	if err != nil {
		conn.Close()
		return nil, err
	}

	svcDesc, err := files.FindDescriptorByName(protoreflect.FullName(serviceName))
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("find service %s: %w", serviceName, err)
	}
	sd, ok := svcDesc.(protoreflect.ServiceDescriptor)
	if !ok {
		conn.Close()
		return nil, fmt.Errorf("%s is not a service descriptor", serviceName)
	}
	md := sd.Methods().ByName(methodName)
	if md == nil {
		conn.Close()
		return nil, fmt.Errorf("method %s not found on %s", methodName, serviceName)
	}

	return &Client{
		addr:   addr,
		conn:   conn,
		reqMD:  md.Input(),
		respMD: md.Output(),
	}, nil
}

// Close releases the gRPC connection.
func (c *Client) Close() error { return c.conn.Close() }

// Call sends reqJSON (a JSON fragment like `{"get_status":{}}`) to the dish
// and returns the response as JSON bytes.
func (c *Client) Call(ctx context.Context, reqJSON []byte) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, defaultCallMS*time.Millisecond)
	defer cancel()

	req := dynamicpb.NewMessage(c.reqMD)
	if err := protojson.Unmarshal(reqJSON, req); err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	resp := dynamicpb.NewMessage(c.respMD)
	if err := c.conn.Invoke(callCtx, methodPath, req, resp); err != nil {
		return nil, fmt.Errorf("rpc %s.%s: %w", serviceName, methodName, err)
	}
	out, err := protojson.MarshalOptions{
		UseProtoNames:   false, // keep camelCase to match existing bash/jq usage
		EmitUnpopulated: false,
	}.Marshal(resp)
	if err != nil {
		return nil, fmt.Errorf("marshal response: %w", err)
	}
	return out, nil
}

// resolveFiles opens a reflection stream and pulls the FileDescriptorProto
// that contains `symbol`, transitively walking dependencies. Returns a
// protoregistry.Files ready for descriptor lookups.
func resolveFiles(ctx context.Context, conn *grpc.ClientConn, symbol string) (*protoregistry.Files, error) {
	client := refpb.NewServerReflectionClient(conn)
	stream, err := client.ServerReflectionInfo(ctx)
	if err != nil {
		return nil, fmt.Errorf("open reflection stream: %w", err)
	}
	defer stream.CloseSend()

	// Keyed by file name so we don't re-fetch (reflection returns the file
	// that defines the symbol; we then walk imports).
	rawFiles := map[string]*descriptorpb.FileDescriptorProto{}

	// Fetch the file containing the requested symbol.
	if err := fetchFilesBySymbol(stream, symbol, rawFiles); err != nil {
		return nil, err
	}

	// Transitively fetch imports until closure.
	for {
		missing := map[string]struct{}{}
		for _, fd := range rawFiles {
			for _, dep := range fd.Dependency {
				if _, ok := rawFiles[dep]; !ok {
					missing[dep] = struct{}{}
				}
			}
		}
		if len(missing) == 0 {
			break
		}
		for name := range missing {
			if err := fetchFilesByName(stream, name, rawFiles); err != nil {
				return nil, err
			}
		}
	}

	return buildRegistry(rawFiles)
}

func fetchFilesBySymbol(stream refpb.ServerReflection_ServerReflectionInfoClient, sym string, out map[string]*descriptorpb.FileDescriptorProto) error {
	if err := stream.Send(&refpb.ServerReflectionRequest{
		MessageRequest: &refpb.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: sym},
	}); err != nil {
		return fmt.Errorf("reflect send symbol %s: %w", sym, err)
	}
	return recvFileDescriptors(stream, out)
}

func fetchFilesByName(stream refpb.ServerReflection_ServerReflectionInfoClient, name string, out map[string]*descriptorpb.FileDescriptorProto) error {
	if err := stream.Send(&refpb.ServerReflectionRequest{
		MessageRequest: &refpb.ServerReflectionRequest_FileByFilename{FileByFilename: name},
	}); err != nil {
		return fmt.Errorf("reflect send file %s: %w", name, err)
	}
	return recvFileDescriptors(stream, out)
}

func recvFileDescriptors(stream refpb.ServerReflection_ServerReflectionInfoClient, out map[string]*descriptorpb.FileDescriptorProto) error {
	resp, err := stream.Recv()
	if err == io.EOF {
		return fmt.Errorf("reflection stream closed unexpectedly")
	}
	if err != nil {
		return fmt.Errorf("reflect recv: %w", err)
	}
	errResp := resp.GetErrorResponse()
	if errResp != nil {
		return fmt.Errorf("reflect error %d: %s", errResp.ErrorCode, errResp.ErrorMessage)
	}
	fr := resp.GetFileDescriptorResponse()
	if fr == nil {
		return fmt.Errorf("reflect: unexpected response type")
	}
	for _, raw := range fr.FileDescriptorProto {
		fd := &descriptorpb.FileDescriptorProto{}
		if err := proto.Unmarshal(raw, fd); err != nil {
			return fmt.Errorf("parse FileDescriptorProto: %w", err)
		}
		out[fd.GetName()] = fd
	}
	return nil
}

// buildRegistry turns raw FileDescriptorProtos into a protoregistry.Files,
// registering files in dependency order so protodesc.NewFile can resolve
// imports.
func buildRegistry(raw map[string]*descriptorpb.FileDescriptorProto) (*protoregistry.Files, error) {
	files := &protoregistry.Files{}
	// Topological-ish: repeatedly register whichever files have all their
	// deps already registered. N is small (~5), so quadratic is fine.
	remaining := make(map[string]*descriptorpb.FileDescriptorProto, len(raw))
	for k, v := range raw {
		remaining[k] = v
	}
	for len(remaining) > 0 {
		progressed := false
		for name, fd := range remaining {
			depsReady := true
			for _, dep := range fd.Dependency {
				if _, err := files.FindFileByPath(dep); err != nil {
					// Dep also isn't in remaining — treat as well-known and
					// fall through to protodesc.NewFile which consults the
					// global registry for well-known types.
					if _, ok := remaining[dep]; ok {
						depsReady = false
						break
					}
				}
			}
			if !depsReady {
				continue
			}
			file, err := protodesc.NewFile(fd, files)
			if err != nil {
				return nil, fmt.Errorf("build descriptor for %s: %w", name, err)
			}
			if err := files.RegisterFile(file); err != nil {
				return nil, fmt.Errorf("register %s: %w", name, err)
			}
			delete(remaining, name)
			progressed = true
		}
		if !progressed {
			return nil, fmt.Errorf("circular or unresolved dependencies among %d files", len(remaining))
		}
	}
	return files, nil
}
