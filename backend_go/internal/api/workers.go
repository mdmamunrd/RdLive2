package api

import (
	"context"
	"log"
	"net/http"
	"time"

	"rdlive/internal/pgnotify"
	"rdlive/internal/realtime"
	"rdlive/internal/worker"
)

// Server is the HTTP handler plus the background workers that make the app "live".
type Server struct {
	a    *API
	disp *realtime.Dispatcher
}

func NewServer(d Deps) *Server {
	if d.Publisher == nil {
		d.Publisher = realtime.Nop{}
	}
	if d.Hub == nil {
		d.Hub = realtime.NewHub(5) // at most 5 sockets per user (phone, tablet, web ...)
	}
	a := &API{d}
	return &Server{a: a, disp: realtime.NewDispatcher(d.Hub, a.LoadMessageJSON)}
}

func (s *Server) Handler() http.Handler { return s.a.handler() }

// Start launches the background workers; they stop when ctx is cancelled. Non-blocking.
//
//  1. room/chat listener: PostgreSQL NOTIFY -> hub -> WebSocket clients (reconnects by itself)
//  2. chat message loader (keeps message order)
//  3. PK ticker: closes expired PK battles every PK_TICK_SECONDS (2-5)
//  4. media janitor: hourly, removes chat images that were uploaded but never sent
func (s *Server) Start(ctx context.Context) {
	src := &pgnotify.Listener{URL: s.a.Cfg.DatabaseURL}
	go realtime.RunListener(ctx, src,
		[]string{realtime.ChannelRoom, realtime.ChannelChat},
		s.disp.Handle, s.disp.Resync, log.Printf)
	go s.disp.RunChat(ctx)
	go worker.RunPKTicker(ctx, s.a.Cfg.PKTick, s.a.finishDuePK, log.Printf)
	go worker.RunEvery(ctx, time.Hour, "media_cleanup", s.a.cleanupMedia, log.Printf)
}
