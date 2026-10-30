package api

import (
	"context"
	"log"
)

// cleanupMedia removes chat images that were reserved/uploaded but never attached to a message
// (older than 24 h). The database marks them 'deleted' first (media_expire_unused, safe with several
// replicas); then the bytes are removed from storage. A failed storage delete is logged and not retried
// (the row is already closed): keep a bucket lifecycle rule as the safety net.
func (a *API) cleanupMedia(ctx context.Context) error {
	if a.Media == nil {
		return nil
	}
	const batch = 200
	for round := 0; round < 10; round++ { // at most 2000 objects per run; the next run continues
		rows, err := a.DB.Query(ctx, `select storage, storage_key from media_expire_unused('24 hours', $1)`, batch)
		if err != nil {
			return err
		}
		type obj struct{ storage, key string }
		var objs []obj
		for rows.Next() {
			var o obj
			if err := rows.Scan(&o.storage, &o.key); err != nil {
				rows.Close()
				return err
			}
			objs = append(objs, o)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		removed := 0
		for _, o := range objs {
			if o.storage != a.Media.Kind() {
				continue // belongs to another storage backend (the deployment switched): never touch it
			}
			if err := a.Media.Delete(ctx, o.key); err != nil {
				log.Printf("media cleanup: delete %s: %v", o.key, err)
				continue
			}
			removed++
		}
		if len(objs) > 0 {
			log.Printf("media cleanup: expired %d unused upload(s), removed %d object(s)", len(objs), removed)
		}
		if len(objs) < batch {
			return nil
		}
	}
	return nil
}
