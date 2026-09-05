import { jsPDF } from 'jspdf'
import { requireSupabase } from './lib/supabase'
import { uploadPdfToDrive } from './google-drive-storage'

const db = () => requireSupabase()
const originalSave = jsPDF.prototype.save
const originalOutput = jsPDF.prototype.output
let context = null
let uploading = false

function classify(name = '') {
  const n = name.toLowerCase()
  if (n.includes('prescription') || n.includes('prescrip')) return { type: 'Prescription', folder: 'Prescriptions' }
  if (n.includes('lab') || n.includes('report')) return { type: 'Lab Report', folder: 'Lab Reports' }
  if (n.includes('bill') || n.includes('receipt') || n.includes('invoice')) return { type: 'Bill', folder: 'Bills' }
  if (n.includes('discharge')) return { type: 'Discharge Summary', folder: 'Discharge Summaries' }
  return { type: 'Medical Document', folder: 'Medical Documents' }
}

function patientNoFrom(name = '') {
  return name.match(/\bPT-[A-Z0-9-]+\b/i)?.[0] || context?.patientNo || null
}

async function uploadGeneratedPdf(blob, fileName) {
  if (uploading || !blob || !fileName) return
  const patientNo = patientNoFrom(fileName)
  if (!patientNo) return
  uploading = true
  try {
    const { data: patient, error } = await db().from('patients').select('*').eq('patient_no', patientNo).single()
    if (error || !patient) return
    const meta = classify(fileName)
    await uploadPdfToDrive({
      patient,
      patientId: patient.id,
      documentType: meta.type,
      fileName,
      blob,
      subfolder: meta.folder,
      metadata: { source: 'automatic-pdf-hook' }
    })
    window.dispatchEvent(new CustomEvent('doctor-clinic-drive-uploaded', { detail: { patientId: patient.id, fileName, documentType: meta.type } }))
  } catch (e) {
    console.warn('Google Drive automatic PDF upload failed:', e?.message || e)
  } finally {
    uploading = false
  }
}

if (!window.__doctorClinicPdfAutoUploadInstalled) {
  window.__doctorClinicPdfAutoUploadInstalled = true
  document.addEventListener('click', event => {
    const row = event.target.closest?.('.clinical-row')
    if (!row) return
    const match = (row.innerText || '').match(/\bPT-[A-Z0-9-]+\b/i)
    if (match) context = { patientNo: match[0] }
  }, true)

  jsPDF.prototype.save = function (filename, options) {
    if (filename) context = { ...(context || {}), patientNo: patientNoFrom(filename) || context?.patientNo, fileName: filename }
    const result = originalSave.call(this, filename, options)
    try {
      const blob = originalOutput.call(this, 'blob')
      const name = filename || context?.fileName || `clinical-document-${Date.now()}.pdf`
      void uploadGeneratedPdf(blob, name)
    } catch (e) { console.warn('Unable to prepare PDF for Drive upload:', e?.message || e) }
    return result
  }

  jsPDF.prototype.output = function (type, options) {
    const result = originalOutput.call(this, type, options)
    if (type === 'blob' && context?.patientNo) {
      const name = context.fileName || `${context.patientNo}-clinical-document-${Date.now()}.pdf`
      void uploadGeneratedPdf(result, name)
    }
    return result
  }
}
