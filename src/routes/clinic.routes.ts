/**
 * 🏥 CLINIQUE — pont ordonnance → pharmacie 224.
 *   POST /api/v2/clinic/prescriptions/:id/send-to-pharmacy  { pharmacy_id }
 * Génère un PDF d'ordonnance (bucket PRIVÉ `prescriptions`, dossier clinic/) et INJECTE une
 * ligne dans la table `prescriptions` EXISTANTE de la pharmacie choisie (status='pending') →
 * elle entre dans le flux pharmacie NORMAL (validation → devis → paiement) sans le modifier.
 * Aucun contenu médical dans les notifications. Idempotent. Compte patient lié obligatoire.
 */
import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { jsPDF } from 'jspdf';

const router = Router();

interface RxLine { medication?: string; dosage?: string; duration?: string; instructions?: string }

function buildPrescriptionPdf(opts: {
  clinicName: string; patientName: string; patientPhone?: string | null; lines: RxLine[]; dateStr: string;
}): Buffer {
  const doc = new jsPDF();
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(4, 67, 158);
  doc.text(opts.clinicName || 'Clinique', 20, 20);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(80, 80, 80);
  doc.text('ORDONNANCE MÉDICALE', 20, 28);
  doc.setDrawColor(200, 200, 200); doc.line(20, 32, 190, 32);

  doc.setTextColor(30, 30, 30); doc.setFontSize(11);
  doc.text(`Patient : ${opts.patientName}`, 20, 42);
  if (opts.patientPhone) doc.text(`Tél : ${opts.patientPhone}`, 20, 48);
  doc.text(`Date : ${opts.dateStr}`, 150, 42);

  let y = 62;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(12); doc.text('Prescription', 20, y); y += 8;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(11);
  (opts.lines || []).forEach((l, i) => {
    if (y > 270) { doc.addPage(); y = 20; }
    const head = `${i + 1}. ${l.medication || ''}${l.dosage ? ' — ' + l.dosage : ''}`;
    doc.setFont('helvetica', 'bold'); doc.text(head.slice(0, 90), 20, y); y += 6;
    doc.setFont('helvetica', 'normal');
    const sub = [l.duration ? `Durée : ${l.duration}` : '', l.instructions ? `Instructions : ${l.instructions}` : ''].filter(Boolean).join('   ');
    if (sub) { doc.setTextColor(90, 90, 90); doc.text(doc.splitTextToSize(sub, 165), 26, y); y += 6 + Math.floor(sub.length / 80) * 5; doc.setTextColor(30, 30, 30); }
    y += 2;
  });

  doc.setFontSize(8); doc.setTextColor(150, 150, 150);
  doc.text('Ordonnance émise via 224Solutions — le pharmacien valide et chiffre les médicaments.', 20, 288);
  return Buffer.from(doc.output('arraybuffer'));
}

router.post('/prescriptions/:id([0-9a-fA-F-]{36})/send-to-pharmacy', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const cpId = req.params.id;
    const pharmacyId: string | undefined = req.body?.pharmacy_id;
    if (!pharmacyId) { res.status(400).json({ success: false, error: 'pharmacy_id requis' }); return; }

    const { data: cp } = await supabaseAdmin.from('clinic_prescriptions')
      .select('id, professional_service_id, patient_id, lines, status, sent_prescription_id, pdf_path')
      .eq('id', cpId).maybeSingle();
    if (!cp) { res.status(404).json({ success: false, error: 'Ordonnance introuvable' }); return; }

    const { data: patient } = await supabaseAdmin.from('clinic_patients')
      .select('id, user_id, full_name, phone').eq('id', (cp as any).patient_id).maybeSingle();
    if (!patient) { res.status(404).json({ success: false, error: 'Patient introuvable' }); return; }

    // Autorisation : le PATIENT lié OU le praticien propriétaire de la clinique.
    const isPatient = (patient as any).user_id === userId;
    let isOwner = false;
    if (!isPatient) {
      const { data: svc } = await supabaseAdmin.from('professional_services').select('user_id').eq('id', (cp as any).professional_service_id).maybeSingle();
      isOwner = (svc as any)?.user_id === userId;
    }
    if (!isPatient && !isOwner) { res.status(403).json({ success: false, error: 'Non autorisé' }); return; }

    // Compte 224 lié obligatoire (client_id du flux pharmacie).
    if (!(patient as any).user_id) {
      res.status(409).json({ success: false, error: 'Le patient doit avoir un compte 224 lié (sinon ordonnance papier).', error_code: 'PATIENT_SANS_COMPTE' }); return;
    }

    // Pharmacie active.
    const { data: pharma } = await supabaseAdmin.from('professional_services').select('id, name, status').eq('id', pharmacyId).maybeSingle();
    if (!pharma || (pharma as any).status !== 'active') { res.status(404).json({ success: false, error: 'Pharmacie introuvable ou inactive' }); return; }

    // Idempotence : déjà envoyée à CETTE pharmacie et non refusée → on renvoie l'existante.
    if ((cp as any).sent_prescription_id) {
      const { data: ex } = await supabaseAdmin.from('prescriptions').select('id, pharmacy_id, status').eq('id', (cp as any).sent_prescription_id).maybeSingle();
      if (ex && (ex as any).pharmacy_id === pharmacyId && (ex as any).status !== 'refused') {
        res.json({ success: true, already: true, prescription_id: (ex as any).id }); return;
      }
    }

    // PDF (généré une fois, réutilisé).
    let pdfPath = (cp as any).pdf_path as string | null;
    if (!pdfPath) {
      const { data: clinic } = await supabaseAdmin.from('professional_services').select('name, business_name').eq('id', (cp as any).professional_service_id).maybeSingle();
      const buf = buildPrescriptionPdf({
        clinicName: (clinic as any)?.business_name || (clinic as any)?.name || 'Clinique',
        patientName: (patient as any).full_name || 'Patient',
        patientPhone: (patient as any).phone,
        lines: Array.isArray((cp as any).lines) ? (cp as any).lines : [],
        dateStr: new Date().toLocaleDateString('fr-FR'),
      });
      pdfPath = `clinic/${cpId}.pdf`;
      const up = await supabaseAdmin.storage.from('prescriptions').upload(pdfPath, buf, { contentType: 'application/pdf', upsert: true });
      if (up.error) { logger.error(`[clinic/send] upload PDF: ${up.error.message}`); res.status(500).json({ success: false, error: 'Génération du PDF impossible' }); return; }
      await supabaseAdmin.from('clinic_prescriptions').update({ pdf_path: pdfPath }).eq('id', cpId);
    }

    // Injection dans le flux pharmacie EXISTANT (status='pending' → file du pharmacien en realtime).
    const { data: presc, error: insErr } = await supabaseAdmin.from('prescriptions').insert({
      client_id: (patient as any).user_id,
      pharmacy_id: pharmacyId,
      photos: [pdfPath],
      status: 'pending',
      customer_name: ((patient as any).full_name || '').slice(0, 200) || null,
      customer_phone: ((patient as any).phone || '').slice(0, 20) || null,
    }).select('id').single();
    if (insErr || !presc) { logger.error(`[clinic/send] insert prescriptions: ${insErr?.message}`); res.status(500).json({ success: false, error: "Envoi à la pharmacie impossible" }); return; }

    await supabaseAdmin.from('clinic_prescriptions').update({ status: 'sent_to_pharmacy', sent_prescription_id: (presc as any).id }).eq('id', cpId);

    // Notification patient — AUCUN contenu médical.
    try {
      await supabaseAdmin.from('notifications').insert({
        user_id: (patient as any).user_id,
        title: 'Votre ordonnance est disponible',
        message: 'Votre ordonnance a été transmise à la pharmacie choisie. Suivez son traitement dans votre espace.',
        type: 'prescription',
        read: false,
        metadata: { entity_type: 'clinic_prescription', prescription_id: (presc as any).id },
      });
    } catch { /* best-effort */ }

    res.json({ success: true, prescription_id: (presc as any).id, pdf_path: pdfPath });
  } catch (e: any) {
    logger.error(`[clinic/send-to-pharmacy] ${e?.message}`);
    res.status(500).json({ success: false, error: "Erreur lors de l'envoi de l'ordonnance" });
  }
});

export default router;
