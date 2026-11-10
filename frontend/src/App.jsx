import React, { useState, useEffect } from 'react';
const API_BASE = import.meta.env.VITE_API_BASE || '';
export default function App() {
  const [deployments, setDeployments] = useState([]);
  const [backendAvailable, setBackendAvailable] = useState(false);
  const [loading, setLoading] = useState(true);
  const [form, setForm] = useState({ name: '', node: 'pve', type: 'lxc' });
  useEffect(() => {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 3000);
    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => { if (r.ok) setBackendAvailable(true); })
      .catch(() => {})
      .finally(() => { clearTimeout(t); setLoading(false); });
  }, []);
  useEffect(() => {
    if (!backendAvailable) return;
    fetch(`${API_BASE}/api/deployments`).then(r => r.json()).then(setDeployments).catch(() => {});
  }, [backendAvailable]);
  const handleDeploy = async (e) => {
    e.preventDefault();
    if (!backendAvailable) return;
    const r = await fetch(`${API_BASE}/api/deploy`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...form, cores: 2, memory: 2048 }),
    });
    if (r.ok) { alert('Deployment triggered!'); window.location.reload(); }
    else alert('Deployment failed.');
  };
  if (loading) return <p style={{ padding: 40 }}>Checking backend…</p>;
  return (
    <div style={{ fontFamily: 'sans-serif', maxWidth: 800, margin: '40px auto', padding: 20 }}>
      <h2>Proxmox Remote Orchestration Console</h2>
      {!backendAvailable && (
        <div style={{ background: '#fff3cd', color: '#856404', padding: 12, borderRadius: 4, marginBottom: 20 }}>
          ⚠️ Backend unreachable. Running in <strong>demo mode</strong> — deployment controls are disabled.
        </div>
      )}
      <form onSubmit={handleDeploy} style={{ display: 'flex', gap: 10, marginBottom: 20, opacity: backendAvailable ? 1 : 0.5 }}>
        <input type="text" placeholder="Instance Name" value={form.name}
          onChange={e => setForm({ ...form, name: e.target.value })} required disabled={!backendAvailable} />
        <select value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} disabled={!backendAvailable}>
          <option value="lxc">LXC</option><option value="vm">VM</option>
        </select>
        <input type="text" placeholder="Target Node" value={form.node}
          onChange={e => setForm({ ...form, node: e.target.value })} required disabled={!backendAvailable} />
        <button type="submit" disabled={!backendAvailable}>Deploy</button>
      </form>
      <h3>Deployment History</h3>
      <table border="1" cellPadding="10" style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead><tr><th>ID</th><th>Name</th><th>Type</th><th>Node</th><th>Status</th><th>Timestamp</th></tr></thead>
        <tbody>
          {deployments.length === 0 && <tr><td colSpan="6" style={{ textAlign: 'center' }}>No deployments.</td></tr>}
          {deployments.map(d => (
            <tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td>
              <td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
