import React, { useState, useEffect } from 'react';
const API_BASE = import.meta.env.VITE_API_BASE || '';
export default function App() {
  const [deployments, setDeployments] = useState([]);
  const [state, setState] = useState({
    loading: true, backendOnline: false,
    proxmoxConfigured: false, proxmoxConnected: false, detail: '',
  });
  const [form, setForm] = useState({ name: '', node: 'pve', type: 'lxc' });

  useEffect(() => {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 3000);
    const offline = (d='') => setState({ loading:false, backendOnline:false,
      proxmoxConfigured:false, proxmoxConnected:false, detail:d });
    fetch(`${API_BASE}/api/health`, { signal: c.signal })
      .then(r => {
        if (!r.ok) { offline(`HTTP ${r.status}`); return; }
        return fetch(`${API_BASE}/api/status`)
          .then(r2 => r2.ok ? r2.json() : Promise.reject(new Error(`HTTP ${r2.status}`)))
          .then(s => setState({ loading:false, backendOnline:true,
            proxmoxConfigured:s.proxmox_configured,
            proxmoxConnected:s.proxmox_connected, detail:s.detail||'' }));
      })
      .catch(err => offline(err?.message || 'network error'))
      .finally(() => clearTimeout(t));
  }, []);

  useEffect(() => {
    if (!state.backendOnline) return;
    fetch(`${API_BASE}/api/deployments`).then(r => r.ok ? r.json() : [])
      .then(setDeployments).catch(() => {});
  }, [state.backendOnline]);

  const handleDeploy = async (e) => {
    e.preventDefault(); if (!state.proxmoxConnected) return;
    const r = await fetch(`${API_BASE}/api/deploy`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...form, cores: 2, memory: 2048 }) });
    if (r.ok) { alert('Deployment triggered!'); window.location.reload(); }
    else { const j = await r.json().catch(() => ({})); alert('Deploy failed: ' + (j.detail || r.status)); }
  };

  if (state.loading) return <p style={{ padding: 40 }}>Checking backend…</p>;
  const enabled = state.backendOnline && state.proxmoxConnected;
  let banner;
  if (!state.backendOnline) banner = { bg:'#fff3cd', color:'#856404',
    text:`⚠️ Backend unreachable${state.detail?` (${state.detail})`:''}. Demo mode.` };
  else if (!state.proxmoxConfigured) banner = { bg:'#cfe2ff', color:'#084298',
    text:'ℹ️ Backend online. Proxmox not configured — fill PROXMOX_* in backend/.env.' };
  else if (!state.proxmoxConnected) banner = { bg:'#fff3cd', color:'#856404',
    text:`⚠️ Proxmox configured but unreachable: ${state.detail}` };
  else banner = { bg:'#d1e7dd', color:'#0f5132', text:'✅ Backend online, Proxmox connected.' };

  return (
    <div style={{ fontFamily:'sans-serif', maxWidth:800, margin:'40px auto', padding:20 }}>
      <h2>Proxmox Remote Orchestration Console</h2>
      <div style={{ background:banner.bg, color:banner.color, padding:12, borderRadius:4, marginBottom:20 }}>{banner.text}</div>
      <form onSubmit={handleDeploy} style={{ display:'flex', gap:10, marginBottom:20, opacity:enabled?1:0.5 }}>
        <input type="text" placeholder="Instance Name" value={form.name}
          onChange={e => setForm({ ...form, name:e.target.value })} required disabled={!enabled} />
        <select value={form.type} onChange={e => setForm({ ...form, type:e.target.value })} disabled={!enabled}>
          <option value="lxc">LXC</option><option value="vm">VM</option>
        </select>
        <input type="text" placeholder="Target Node" value={form.node}
          onChange={e => setForm({ ...form, node:e.target.value })} required disabled={!enabled} />
        <button type="submit" disabled={!enabled}>Deploy</button>
      </form>
      <h3>Deployment History</h3>
      <table border="1" cellPadding="10" style={{ width:'100%', borderCollapse:'collapse' }}>
        <thead><tr><th>ID</th><th>Name</th><th>Type</th><th>Node</th><th>Status</th><th>Timestamp</th></tr></thead>
        <tbody>
          {deployments.length===0 && <tr><td colSpan="6" style={{ textAlign:'center' }}>No deployments.</td></tr>}
          {deployments.map(d => (
            <tr key={d.id}><td>{d.id}</td><td>{d.name}</td><td>{d.type}</td>
              <td>{d.target_node}</td><td>{d.status}</td><td>{d.created_at}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
