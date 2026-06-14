import { useEffect, useState } from 'react'
import styles from './App.module.css'

const STATUS_PAGE_SLUG = 'main'

const STATUS = {
  UP:       { label: 'uppe',     color: '#22c55e' },
  DOWN:     { label: 'nere',     color: '#ef4444' },
  PENDING:  { label: 'väntar',   color: '#eab308' },
  UNKNOWN:  { label: 'okänd',    color: '#555'    },
}

function statusOf(heartbeat) {
  if (!heartbeat) return STATUS.UNKNOWN
  if (heartbeat.status === 1) return STATUS.UP
  if (heartbeat.status === 0) return STATUS.DOWN
  return STATUS.PENDING
}

function uptime(uptimeList, id) {
  const val = uptimeList?.[`${id}_24`]
  return val != null ? `${(val * 100).toFixed(1)}%` : '—'
}

export default function App() {
  const [monitors, setMonitors] = useState([])
  const [heartbeats, setHeartbeats] = useState({})
  const [uptimeList, setUptimeList] = useState({})
  const [error, setError] = useState(null)
  const [lastUpdated, setLastUpdated] = useState(null)

  async function fetchStatus() {
    try {
      const [pageRes, hbRes] = await Promise.all([
        fetch(`/api/uptime/api/status-page/${STATUS_PAGE_SLUG}`),
        fetch(`/api/uptime/api/status-page/heartbeat/${STATUS_PAGE_SLUG}`),
      ])

      if (!pageRes.ok || !hbRes.ok) throw new Error('Kunde inte hämta status')

      const page = await pageRes.json()
      const hb = await hbRes.json()

      const allMonitors = page.publicGroupList?.flatMap(g => g.monitorList) ?? []
      setMonitors(allMonitors)
      setHeartbeats(hb.heartbeatList ?? {})
      setUptimeList(hb.uptimeList ?? {})
      setLastUpdated(new Date())
      setError(null)
    } catch (e) {
      setError(e.message)
    }
  }

  useEffect(() => {
    fetchStatus()
    const id = setInterval(fetchStatus, 30_000)
    return () => clearInterval(id)
  }, [])

  const allUp = monitors.length > 0 && monitors.every(m => {
    const hb = heartbeats[m.id]?.[0]
    return statusOf(hb) === STATUS.UP
  })

  return (
    <div className={styles.layout}>
      <header className={styles.header}>
        <div className={styles.headerInner}>
          <span className={styles.site}>encab.se</span>
          <div className={styles.overall}>
            {error ? (
              <span style={{ color: STATUS.UNKNOWN.color }}>● ej ansluten</span>
            ) : monitors.length === 0 ? (
              <span style={{ color: STATUS.UNKNOWN.color }}>● inga tjänster konfigurerade</span>
            ) : allUp ? (
              <span style={{ color: STATUS.UP.color }}>● alla tjänster fungerar</span>
            ) : (
              <span style={{ color: STATUS.DOWN.color }}>● driftstörning pågår</span>
            )}
          </div>
        </div>
      </header>

      <main className={styles.main}>
        {error && (
          <div className={styles.errorBox}>{error}</div>
        )}

        {!error && monitors.length === 0 && (
          <div className={styles.empty}>
            Inga tjänster är konfigurerade i Uptime Kuma än.
          </div>
        )}

        {monitors.map(m => {
          const hb = heartbeats[m.id]?.[0]
          const s = statusOf(hb)
          return (
            <div key={m.id} className={styles.row}>
              <div className={styles.rowLeft}>
                <span className={styles.dot} style={{ background: s.color, boxShadow: `0 0 6px ${s.color}` }} />
                <span className={styles.name}>{m.name}</span>
              </div>
              <div className={styles.rowRight}>
                <span className={styles.uptime} title="drifttid senaste 24h">
                  {uptime(uptimeList, m.id)}
                </span>
                <span className={styles.statusLabel} style={{ color: s.color }}>
                  {s.label}
                </span>
              </div>
            </div>
          )
        })}
      </main>

      {lastUpdated && (
        <footer className={styles.footer}>
          uppdaterad {lastUpdated.toLocaleTimeString('sv-SE')}
        </footer>
      )}
    </div>
  )
}
