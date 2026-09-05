import { requireSupabase } from './lib/supabase'

const db = () => requireSupabase()
const FUNCTION = 'google-drive'

function bytesToBase64(bytes) {
  let binary = ''
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  return btoa(binary)
}

export async function ensurePatientDriveFolder(patient) {
  if (!patient?.id || !patient?.patient_no) throw new Error('Patient ID and patient number are required')
  const { data, error } = await db().functions.invoke(FUNCTION, {
    body: { action: 'ensure_patient_folder', patient_id: patient.id, patient_no: patient.patient_no }
  })
  if (error) throw error
  return data
}

export async function createDriveDocumentRecord({ patientId, encounterId, documentType, fileName, mimeType = 'application/pdf', metadata = {} }) {
  const user = (await db().auth.getUser()).data.user
  const { data, error } = await db().from('documents').insert({
    patient_id: patientId,
    encounter_id: encounterId || null,
    document_type: documentType,
    file_name: fileName,
    mime_type: mimeType,
    status: 'pending',
    uploaded_by: user?.id || null,
    metadata
  }).select().single()
  if (error) throw error
  return data
}

export async function uploadPdfToDrive({ patient, patientId, encounterId, documentType, fileName, blob, subfolder = 'Medical Documents', metadata = {} }) {
  const record = await createDriveDocumentRecord({ patientId: patientId || patient?.id, encounterId, documentType, fileName, mimeType: 'application/pdf', metadata })
  try {
    await ensurePatientDriveFolder(patient)
    const bytes = new Uint8Array(await blob.arrayBuffer())
    const { data, error } = await db().functions.invoke(FUNCTION, {
      body: {
        action: 'upload_base64',
        document_id: record.id,
        patient_no: patient.patient_no,
        name: fileName,
        mime_type: 'application/pdf',
        subfolder,
        base64: bytesToBase64(bytes)
      }
    })
    if (error) throw error
    return data
  } catch (error) {
    await db().from('documents').update({ status: 'failed', error_message: error?.message || String(error) }).eq('id', record.id)
    throw error
  }
}

export async function listPatientDocuments(patientId) {
  const { data, error } = await db().functions.invoke(FUNCTION, { body: { action: 'list_patient_documents', patient_id: patientId } })
  if (error) throw error
  return data?.documents || []
}

export function installPdfDriveHooks() {
  if (window.__doctorClinicDriveHooksInstalled) return
  window.__doctorClinicDriveHooksInstalled = true
  window.__doctorClinicDriveContext = null
  document.addEventListener('click', event => {
    const row = event.target.closest?.('.clinical-row')
    if (!row) return
    const text = row.innerText || ''
    const match = text.match(/\b(PT-[A-Z0-9-]+)\b/i)
    if (match) window.__doctorClinicDriveContext = { patientNo: match[1] }
  }, true)
  window.__doctorClinicDriveUpload = uploadPdfToDrive
}
