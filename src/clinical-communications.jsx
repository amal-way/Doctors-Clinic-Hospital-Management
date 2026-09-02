import React,{useEffect,useMemo,useState}from'react';
import{createRoot}from'react-dom/client';
import{FileText,MessageCircle,Send,X,FlaskConical,RefreshCw}from'lucide-react';
import{jsPDF}from'jspdf';
import{requireSupabase}from'./lib/supabase';
import'./clinical-communications.css';

const db=()=>requireSupabase();
const CLINIC_NAME=localStorage.getItem('clinic-name')||"Doctor's Clinic";
const WELCOME_NOTE=localStorage.getItem('clinic-welcome-note')||'Welcome to our clinic. Please keep this report for your medical records.';

function safe(v){return v==null||v===''?'—':String(v)}
function lines(doc,text,x,y,max=170){const a=doc.splitTextToSize(String(text||'—'),max);doc.text(a,x,y);return y+(a.length*5)}

async function loadPrescriptions(){
 const s=db();
 const {data,error}=await s.from('prescriptions').select('id,encounter_id,patient_id,doctor_id,status,instructions,approved_at,created_at,lab_findings,patients(full_name,patient_no,date_of_birth,gender,phone,address,blood_group,allergies),encounters(chief_complaint,history,examination,vitals,assessment,plan,created_at),prescription_items(*)').order('created_at',{ascending:false});
 if(error)throw error; return data||[];
}

function makePrescriptionPdf(rx){
 const d=new jsPDF();let y=18;
 d.setFontSize(19);d.text(CLINIC_NAME,20,y);y+=7;
 d.setFontSize(9);d.text('CLINICAL PRESCRIPTION & LAB FINDINGS',20,y);y+=6;
 d.line(20,y,190,y);y+=8;
 d.setFontSize(11);d.text('Welcome',20,y);y+=6;y=lines(d,WELCOME_NOTE,20,y);y+=5;
 d.setFontSize(12);d.text('Patient details',20,y);y+=7;d.setFontSize(10);
 y=lines(d,`Name: ${safe(rx.patients?.full_name)}    Patient ID: ${safe(rx.patients?.patient_no)}`,20,y);
 y=lines(d,`DOB: ${safe(rx.patients?.date_of_birth)}    Gender: ${safe(rx.patients?.gender)}    Blood group: ${safe(rx.patients?.blood_group)}`,20,y);
 y=lines(d,`Phone: ${safe(rx.patients?.phone)}`,20,y);y=lines(d,`Allergies: ${safe(rx.patients?.allergies||'None recorded')}`,20,y);y+=4;
 d.setFontSize(12);d.text('Chief complaint / clinical findings',20,y);y+=7;d.setFontSize(10);
 y=lines(d,`Chief complaint: ${safe(rx.encounters?.chief_complaint)}`,20,y);
 y=lines(d,`History: ${safe(rx.encounters?.history)}`,20,y);
 y=lines(d,`Examination: ${safe(rx.encounters?.examination)}`,20,y);
 y=lines(d,`Vitals: ${safe(JSON.stringify(rx.encounters?.vitals||{}))}`,20,y);
 y=lines(d,`Assessment: ${safe(rx.encounters?.assessment)}`,20,y);
 y=lines(d,`Plan: ${safe(rx.encounters?.plan)}`,20,y);y+=4;
 if(y>265){d.addPage();y=18}
 d.setFontSize(12);d.text('Verified laboratory findings',20,y);y+=7;d.setFontSize(10);
 const findings=Array.isArray(rx.lab_findings)?rx.lab_findings:[];
 if(!findings.length){y=lines(d,'No verified laboratory findings available at prescription time.',20,y)}
 findings.forEach(f=>{if(y>270){d.addPage();y=18}y=lines(d,`${safe(f.test_name)} (${safe(f.status)})`,20,y);(f.entries||[]).forEach(e=>{y=lines(d,`• ${safe(e.parameter_name)}: ${safe(e.value_text)} ${safe(e.unit)} | Ref: ${safe(e.reference_range)} | ${safe(e.abnormal_flag||'')}`,24,y)});y+=2});
 if(y>265){d.addPage();y=18}
 d.setFontSize(12);d.text('Medicines / prescription',20,y);y+=7;d.setFontSize(10);
 (rx.prescription_items||[]).forEach((m,i)=>{if(y>270){d.addPage();y=18}y=lines(d,`${i+1}. ${safe(m.medicine_name)} ${safe(m.strength)}`,20,y);y=lines(d,`Dose: ${safe(m.dosage)} | Frequency: ${safe(m.frequency)} | Route: ${safe(m.route)} | Duration: ${safe(m.duration)} | Qty: ${safe(m.quantity)}`,24,y);y=lines(d,`Instructions: ${safe(m.instructions)}`,24,y);y+=2});
 y=lines(d,`Prescription instructions: ${safe(rx.instructions)}`,20,y);
 d.setFontSize(8);d.text(`${CLINIC_NAME} · This document is generated from the clinical record.`,20,286);
 return d;
}

async function sharePrescription(rx){
 const doc=makePrescriptionPdf(rx);const fileName=`${rx.patients?.patient_no||'patient'}-prescription-${new Date().toISOString().slice(0,10)}.pdf`;
 const blob=doc.output('blob');const file=new File([blob],fileName,{type:'application/pdf'});
 const text=`Welcome to ${CLINIC_NAME}.\n\nDear ${safe(rx.patients?.full_name)}, your prescription and verified laboratory findings are enclosed in the clinical PDF.\nPatient ID: ${safe(rx.patients?.patient_no)}\nChief complaint: ${safe(rx.encounters?.chief_complaint)}\n\nPlease keep this PDF for your records.`;
 if(navigator.canShare?.({files:[file]})&&navigator.share){try{await navigator.share({files:[file],title:`${CLINIC_NAME} Prescription`,text});return 'shared'}catch(e){if(e?.name==='AbortError')return 'cancelled'}}
 const path=`prescriptions/${rx.patients?.patient_no||rx.patient_id}/${Date.now()}-${fileName}`;
 const {error:up}=await db().storage.from('clinical-reports').upload(path,blob,{contentType:'application/pdf',upsert:true});
 if(up)throw up;
 const {data:signed,error:se}=await db().storage.from('clinical-reports').createSignedUrl(path,60*60*24*7);if(se)throw se;
 window.open(`https://wa.me/?text=${encodeURIComponent(`${text}\n\nSecure PDF: ${signed.signedUrl}`)}`,'_blank','noopener,noreferrer');return 'link';
}

function ClinicalPanel(){const[rows,setRows]=useState([]),[open,setOpen]=useState(false),[q,setQ]=useState(''),[busy,setBusy]=useState('');const load=()=>loadPrescriptions().then(setRows).catch(e=>alert(e.message));useEffect(()=>{load()},[]);const filtered=useMemo(()=>rows.filter(x=>`${x.patients?.full_name||''} ${x.patients?.patient_no||''} ${x.encounters?.chief_complaint||''}`.toLowerCase().includes(q.toLowerCase())),[rows,q]);if(!open)return <button className="clinical-share-trigger" onClick={()=>setOpen(true)}><FileText size={16}/> Prescription PDF</button>;return <div className="clinical-overlay"><div className="clinical-modal"><div className="clinical-head"><div><b>Prescription PDF & WhatsApp</b><span>Includes patient details, chief complaint, clinical findings, verified lab findings and every medicine.</span></div><button onClick={()=>setOpen(false)}><X size={18}/></button></div><div className="clinical-tools"><input placeholder="Search patient / complaint" value={q} onChange={e=>setQ(e.target.value)}/><button onClick={load}><RefreshCw size={15}/> Refresh</button></div><div className="clinical-list">{filtered.map(rx=><div className="clinical-row" key={rx.id}><div><b>{rx.patients?.full_name||'—'}</b><span>{rx.patients?.patient_no||'—'} · {rx.encounters?.chief_complaint||'No chief complaint'}</span><small>{(rx.prescription_items||[]).map(x=>x.medicine_name).join(', ')||'No medicines'} · {Array.isArray(rx.lab_findings)?rx.lab_findings.length:0} verified lab test(s)</small></div><div className="clinical-actions"><button onClick={()=>makePrescriptionPdf(rx).save(`${rx.patients?.patient_no||'patient'}-prescription.pdf`)}><FileText size={14}/> PDF</button><button className="wa" disabled={busy===rx.id} onClick={async()=>{try{setBusy(rx.id);await sharePrescription(rx)}catch(e){alert(e.message)}finally{setBusy('')}}}><MessageCircle size={14}/> {busy===rx.id?'Preparing…':'WhatsApp'}</button></div></div>)}{!filtered.length&&<div className="clinical-empty">No prescriptions found.</div>}</div></div></div>}

function inject(){const host=document.querySelector('.header-actions');if(!host||host.querySelector('.clinical-share-root'))return;const el=document.createElement('span');el.className='clinical-share-root';host.prepend(el);createRoot(el).render(<ClinicalPanel/>)}
const mo=new MutationObserver(inject);mo.observe(document.body,{childList:true,subtree:true});inject();