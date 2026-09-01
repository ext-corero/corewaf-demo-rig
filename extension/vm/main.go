// corewaf-rig-pty — the extension's backend service: a WebSocket→PTY bridge so
// the UI can embed a real terminal (xterm.js) into a kit VM.
//
//	POST /session {"kit":"demo","cmd":"vm-ssh"} -> {"token":"..."}
//	GET  /ws?token=...                          -> WS bridged to a PTY running
//	     docker exec -it rig-kit-<kit> <cmd>
//
// Only whitelisted commands on whitelisted containers are spawnable, and each
// session token is single-use — the published localhost port never becomes a
// generic exec service. Binary frames = raw PTY bytes; a text frame of the
// form {"resize":{"cols":N,"rows":M}} resizes the PTY.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

var kits = map[string]bool{"demo": true, "a": true, "b": true}
var cmds = map[string]bool{"vm-ssh": true, "console": true}

type session struct {
	kit, cmd string
	created  time.Time
}

var (
	mu       sync.Mutex
	sessions = map[string]session{}
	upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
)

func newToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func handleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req struct{ Kit, Cmd string }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !kits[req.Kit] || !cmds[req.Cmd] {
		http.Error(w, "kit must be demo|a|b, cmd must be vm-ssh|console", http.StatusBadRequest)
		return
	}
	tok := newToken()
	mu.Lock()
	for t, s := range sessions { // GC stale unclaimed sessions
		if time.Since(s.created) > 2*time.Minute {
			delete(sessions, t)
		}
	}
	sessions[tok] = session{kit: req.Kit, cmd: req.Cmd, created: time.Now()}
	mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]string{"token": tok})
}

func handleWS(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	s, ok := sessions[r.URL.Query().Get("token")]
	delete(sessions, r.URL.Query().Get("token")) // single use
	mu.Unlock()
	if !ok {
		http.Error(w, "unknown or used token", http.StatusForbidden)
		return
	}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	cmd := exec.Command("docker", "exec", "-it", "rig-kit-"+s.kit, s.cmd)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		_ = ws.WriteMessage(websocket.TextMessage, []byte("failed to start: "+err.Error()+"\r\n"))
		return
	}
	defer func() { _ = ptmx.Close(); _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() }()

	go func() { // PTY -> WS
		buf := make([]byte, 32*1024)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				if ws.WriteMessage(websocket.BinaryMessage, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				_ = ws.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, "eof"), time.Now().Add(time.Second))
				return
			}
		}
	}()

	for { // WS -> PTY (+ resize)
		mt, data, err := ws.ReadMessage()
		if err != nil {
			return
		}
		if mt == websocket.TextMessage {
			var m struct {
				Resize *struct{ Cols, Rows uint16 } `json:"resize"`
			}
			if json.Unmarshal(data, &m) == nil && m.Resize != nil {
				_ = pty.Setsize(ptmx, &pty.Winsize{Cols: m.Resize.Cols, Rows: m.Resize.Rows})
				continue
			}
		}
		if _, err := ptmx.Write(data); err != nil {
			return
		}
	}
}

func main() {
	addr := os.Getenv("PTY_ADDR")
	if addr == "" {
		addr = ":53289"
	}
	http.HandleFunc("/session", handleSession)
	http.HandleFunc("/ws", handleWS)
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok") })
	log.Printf("corewaf-rig-pty listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
