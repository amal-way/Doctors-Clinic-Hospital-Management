import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { FileText, ExternalLink, RefreshCw, Upload, X, CheckCircle2, AlertCircle } from 'lucide-react'
import { listPatientDocuments, ensurePatientDriveFolder } from './google-drive-storage'
import { requireSupabase } from './lib/supabase'
import './patient-documents.css'

const db = () => requireSupabase()
const types = ['All', 'Prescription', 'Lab Report', 'Bill', 'Discharge Summary', 'Medical Document']

function DocumentsPanel({ patient, close }) {
  const [rows, setRows] = useState([])
  const [filter, setFilter] = useState('All')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const load = async () => {
    setBusy(true); setMessage('')
    try { setRows(await listPatientDocuments(patient.id)) }
    catch (e) { setMessage(e?.message || 'Unable to load Drive documents') }
    finally { setBusy(false) }
  }
  useEffect(() => { load() }, [patient.id])

  const filtered = useMemo(() => filter === 'All' ? rows : rows.filter(x => x.document_type === filter), [rows, filter])

  async function setupFolder() {
    setBusy(true); setMessage('')
    try { await ensurePatientDriveFolder(patient); setMessage('Patient Drive folder is ready.') }
    catch (e) { setMessage(e?.message || 'Google Drive is not configured') }
    finally { setBusy(false) }
  }

  async function uploadDocument(e) {
    const file = e.target.files?.[0]
    if (!file) return
    setBusy(true); setMessage('Uploading document…')
    try {
      const user = (await db().auth.getUser()).data.user
      const { data: record, error } = await db().from('documents').insert({
        patient_id: patient.id,
        document_type: 'Medical Document',
        file_name: file.name,
        mime_type: file.type || 'application/octet-stream',
        status: 'pending',
        uploaded_by: user?.id || null
      }).select().single()
      if (error) throw error
      const bytes = new Uint8Array(await file.arrayBuffer())
      let binary = ''
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      const { error: driveError } = await db().functions.invoke('google-drive', { body: { action: 'upload_base64', document_id: record.id, patient_no: patient.patient_no, name: file.name, mime_type: file.type || 'application/octet-stream', subfolder: 'Medical Documents', base64: btoa(binary) } })
      if (driveError) throw driveError
      setMessage('Document uploaded to Google Drive.'); await load()
    } catch (e) { setMessage(e?.message || 'Upload failed') }
    finally { setBusy(false); e.target.value = '' }
  }

  return <div className="pd-backdrop"><div className="pd-modal">
    <div className="pd-head"><div><h2>Patient Documents</h2><p>{patient.full_name} · {patient.patient_no}</p></div><button onClick={close}><X size={18}/></button></div>
    <div className="pd-toolbar"><div className="pd-filters">{types.map(t => <button key={t} className={filter === t ? 'active' : ''} onClick={() => setFilter(t)}>{t}</button>)}</div><div className="pd-actions"><button onClick={setupFolder} disabled={busy}><CheckCircle2 size={15}/> Drive folder</button><label className="pd-upload"><Upload size={15}/> Upload<input type="file" onChange={uploadDocument}/></label><button onClick={load} disabled={busy}><RefreshCw size={15}/></button></div></div>
    {message && <div className="pd-message"><AlertCircle size={15}/>{message}</div>}
    <div className="pd-list">{filtered.length ? filtered.map(d => <div className="pd-row" key={d.id}><div className="pd-icon"><FileText size={18}/></div><div className="pd-main"><b>{d.file_name}</b><span>{d.document_type} · {new Date(d.created_at).toLocaleString('en-IN')}</span></div><span className={`pd-status ${d.status}`}>{d.status}</span>{d.drive_web_url && <a href={d.drive_web_url} target="_blank" rel="noreferrer"><ExternalLink size={15}/> Open</a>}</div>) : <div className="pd-empty"><FileText size={30}/><b>No Drive documents yet</b><span>Generated PDFs and uploaded medical documents will appear here.</span></div>}</div>
  </div></div>
}

function inject() {
  document.querySelectorAll('.modal').forEach(modal => {
    if (modal.querySelector('.patient-docs-trigger')) return
    const heading = modal.querySelector('.modalhead h2')
    const title = heading?.textContent || ''
    const match = title.match(/^(.*?)\s·\s(PT-[A-Z0-9-]+)$/i)
    if (!match) return
    const patientNo = match[2]
    const mount = document.createElement('span'); mount.className = 'patient-docs-trigger'
    const button = document.createElement('button'); button.className = 'small'; button.textContent = 'Documents'
    mount.appendChild(button)
    heading.parentElement?.appendChild(mount)
    button.onclick = async () => {
      const { data } = await db().from('patients').select('*').eq('patient_no', patientNo).single()
      if (!data) return
      const host = document.createElement('div'); document.body.appendChild(host)
      const root = createRoot(host)
      const close = () => { root.unmount(); host.remove() }
      root.render(<DocumentsPanel patient={data} close={close}/>)
    }
  })
}
const observer = new MutationObserver(inject)
observer.observe(document.body, { childList: true, subtree: true })
inject()
