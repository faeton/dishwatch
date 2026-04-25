// Package dish talks to a local Starlink dish over its gRPC API.
//
// The dish exposes SpaceX.API.Device.Device/Handle, a single Request→Response
// method where the request is a oneof of get_status / get_history / etc. We
// discover the service schema via gRPC reflection at runtime (same trick that
// `grpcurl` uses) so we don't have to vendor .proto files. Callers hand us a
// JSON request fragment; we return the parsed response as JSON bytes, which
// the caller unmarshals into a typed Go struct.
package dish

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jhump/protoreflect/v2/grpcdynamic"
	"github.com/jhump/protoreflect/v2/grpcreflect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/dynamicpb"
)

// ErrUnreachable is returned (wrapped) when we can't reach the dish at all —
// the TCP/HTTP2 dial failed before any RPC happened. Callers can use
// errors.Is to render a friendlier message than the raw "context deadline
// exceeded" surfaced by the gRPC stack.
var ErrUnreachable = errors.New("dish unreachable")

const (
	defaultAddr   = "192.168.100.1:9200"
	serviceName   = "SpaceX.API.Device.Device"
	methodName    = "Handle"
	defaultDialMS = 2000
	defaultCallMS = 4000
)

// Client is a reflection-backed gRPC client for the dish. Zero value is not
// usable; call New.
type Client struct {
	addr   string
	conn   *grpc.ClientConn
	stub   *grpcdynamic.Stub
	method protoreflect.MethodDescriptor
	reqMsg protoreflect.MessageDescriptor
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
		return nil, fmt.Errorf("%w at %s: %w", ErrUnreachable, addr, err)
	}

	rc := grpcreflect.NewClientAuto(ctx, conn)
	fd, err := rc.FileContainingSymbol(protoreflect.FullName(serviceName))
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("reflect %s: %w", serviceName, err)
	}
	var sd protoreflect.ServiceDescriptor
	svcs := fd.Services()
	for i := 0; i < svcs.Len(); i++ {
		if string(svcs.Get(i).FullName()) == serviceName {
			sd = svcs.Get(i)
			break
		}
	}
	if sd == nil {
		conn.Close()
		return nil, fmt.Errorf("service %s not found in reflected file", serviceName)
	}
	md := sd.Methods().ByName(methodName)
	if md == nil {
		conn.Close()
		return nil, fmt.Errorf("method %s not found on %s", methodName, serviceName)
	}

	return &Client{
		addr:   addr,
		conn:   conn,
		stub:   grpcdynamic.NewStub(conn),
		method: md,
		reqMsg: md.Input(),
	}, nil
}

// Close releases the gRPC connection.
func (c *Client) Close() error { return c.conn.Close() }

// Call sends reqJSON (a JSON fragment like `{"get_status":{}}`) to the dish
// and returns the response as JSON bytes. The caller unmarshals into a typed
// struct using encoding/json.
func (c *Client) Call(ctx context.Context, reqJSON []byte) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, defaultCallMS*time.Millisecond)
	defer cancel()

	req := dynamicpb.NewMessage(c.reqMsg)
	if err := protojson.Unmarshal(reqJSON, req); err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	resp, err := c.stub.InvokeRpc(callCtx, c.method, req)
	if err != nil {
		return nil, fmt.Errorf("rpc %s: %w", c.method.FullName(), err)
	}
	out, err := protojson.MarshalOptions{
		UseProtoNames:   false, // keep camelCase to match existing bash/jq usage
		EmitUnpopulated: false,
	}.Marshal(resp.(proto.Message))
	if err != nil {
		return nil, fmt.Errorf("marshal response: %w", err)
	}
	return out, nil
}
