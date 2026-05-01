package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"

	socketio "github.com/zishang520/socket.io/servers/socket/v3"
	"github.com/zishang520/socket.io/v3/pkg/types"
)

// batchTracker tracks problems arriving in batches from competitive-companion.
type batchTracker struct {
	mu     sync.Mutex
	batches map[string]*batch
}

type batch struct {
	ignored  bool
	problems []json.RawMessage
	size     int
}

func newBatchTracker() *batchTracker {
	return &batchTracker{batches: make(map[string]*batch)}
}

// extractQueryType extracts the "type" query parameter from the handshake query.
func extractQueryType(query map[string]any) string {
	v, ok := query["type"]
	if !ok {
		return ""
	}
	switch q := v.(type) {
	case string:
		return q
	case []string:
		if len(q) > 0 {
			return q[0]
		}
	case []any:
		if len(q) > 0 {
			if s, ok := q[0].(string); ok {
				return s
			}
		}
	}
	return ""
}

func main() {
	port := flag.Int("port", 27121, "listening port")
	flag.Parse()

	vscodeClients := &sync.Map{}
	batches := newBatchTracker()

	opts := socketio.DefaultServerOptions()
	opts.SetCors(&types.Cors{Origin: "*", Credentials: true})
	opts.SetServeClient(false)

	server := socketio.NewServer(nil, opts)
	server.SetPath("/ws")

	server.On("connection", func(clients ...any) {
		s := clients[0].(*socketio.Socket)
		hs := s.Handshake()
		clientType := extractQueryType(hs.Query)

		switch clientType {
		case "vscode":
			s.Join("vscode-clients")
			vscodeClients.Store(string(s.Id()), true)
			log.Printf("VSCode client connected: %s", s.Id())

			// Notify browser connection status
			hasBrowser := false
			s.To("browsers").FetchSockets()(func(sockets []*socketio.RemoteSocket, _ error) {
				hasBrowser = len(sockets) > 0
			})
			s.Emit("browserStatus", map[string]bool{"connected": hasBrowser})

			s.On("submit", func(data ...any) {
				if len(data) == 0 {
					return
				}
				log.Printf("Submit request from %s: %v", s.Id(), data[0])
				if err := server.To("browsers").Emit("submitRequest", data[0]); err != nil {
					log.Printf("Error forwarding submit: %v", err)
				}
			})

			s.On("cancelBatch", func(data ...any) {
				if len(data) == 0 {
					return
				}
				if m, ok := data[0].(map[string]any); ok {
					if bid, ok := m["batchId"].(string); ok {
						batches.cancel(bid)
					}
				}
			})

			s.On("claimBatch", func(data ...any) {
				if len(data) == 0 {
					return
				}
				if m, ok := data[0].(map[string]any); ok {
					if bid, ok := m["batchId"].(string); ok {
						server.To("vscode-clients").Emit("batchClaimed", map[string]string{"batchId": bid})
					}
				}
			})

			s.On("disconnect", func(_ ...any) {
				vscodeClients.Delete(string(s.Id()))
				log.Printf("VSCode client disconnected: %s", s.Id())

				remaining := false
				vscodeClients.Range(func(_, _ any) bool {
					remaining = true
					return false
				})
				if !remaining {
					log.Println("No clients connected, shutting down")
					os.Exit(0)
				}
			})

		case "browser":
			s.Join("browsers")
			log.Printf("Browser connected: %s", s.Id())

			// Make first browser active
			isActive := true
			s.To("browsers").FetchSockets()(func(sockets []*socketio.RemoteSocket, _ error) {
				if len(sockets) > 1 {
					isActive = false
				}
			})
			s.Emit("status", map[string]bool{"isActive": isActive})

			// Notify vscode clients
			server.To("vscode-clients").Emit("browserStatus", map[string]bool{"connected": true})

			s.On("setActive", func(_ ...any) {
				log.Printf("Browser %s set as active", s.Id())
			})

			s.On("disconnect", func(_ ...any) {
				log.Printf("Browser disconnected: %s", s.Id())
				hasBrowser := false
				server.To("browsers").FetchSockets()(func(sockets []*socketio.RemoteSocket, _ error) {
					hasBrowser = len(sockets) > 0
				})
				server.To("vscode-clients").Emit("browserStatus", map[string]bool{"connected": hasBrowser})
			})
		}
	})

	mux := http.NewServeMux()
	mux.Handle("/ws/", server.ServeHandler(nil))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, `<html><body><h1>CompetiTest Router</h1><p>Running.</p></body></html>`)
			return
		}

		var problem json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&problem); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		// Forward to vscode clients
		server.To("vscode-clients").Emit("batchAvailable", problem)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":"ok"}`)
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("Router started on port %d", *port)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}

func (b *batchTracker) cancel(batchID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if bt, ok := b.batches[batchID]; ok {
		bt.ignored = true
	}
}

func (b *batchTracker) add(batchID string, size int, problem json.RawMessage, server *socketio.Server) {
	b.mu.Lock()
	defer b.mu.Unlock()

	bt, ok := b.batches[batchID]
	if !ok {
		bt = &batch{size: size}
		b.batches[batchID] = bt
	}
	if bt.ignored {
		return
	}
	bt.problems = append(bt.problems, problem)

	if size != 1 {
		server.To("vscode-clients").Emit("readingBatch", map[string]any{
			"batchId": batchID,
			"count":   len(bt.problems),
			"size":    size,
		})
	}

	if len(bt.problems) >= size && !bt.ignored {
		server.To("vscode-clients").Emit("batchAvailable", map[string]any{
			"batchId":   batchID,
			"problems":  bt.problems,
			"autoImport": true,
		})
		delete(b.batches, batchID)
	}
}
