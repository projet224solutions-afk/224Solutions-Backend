# ARCHIVE_SOLDE_REPORT

Date : 2026-08-04 (même migration `20260804180000`, PROUVÉ rollback).

## ✅ Garde-fou : archivage bloqué tant que le portefeuille organisateur n'est pas vide
`archive_event` : verrouille `organizer_wallets` **FOR UPDATE** (pas de course avec un retrait simultané) →
- `balance > 0` → **REFUS `WALLET_NOT_EMPTY`** (+ montant + devise) — UI : « Videz d'abord le portefeuille ».
- remboursements d'annulation dus (`refund_due`) → **REFUS `REFUNDS_PENDING`**.
- `balance = 0` et aucune dette → archivage normal (historique conservé, billets valides, organisateur désactivé).

## PREUVE : solde 100000 → `{error: WALLET_NOT_EMPTY, balance: 100000, currency: GNF}` ; solde 0 → `{success: true}` ✓.

**« Archivage bloqué tant que le portefeuille organisateur n'est pas vide le 2026-08-04. »**
