# 📖 Manifeste des fonctionnalités — la connaissance du Fatome

Ce dossier est **la mémoire de la plateforme** : ce que chaque fonctionnalité FAIT, par
quelles routes/RPC/tables elle passe, quelles règles métier doivent rester vraies, et de
quoi elle dépend. Le Fatome Fonctionnalités surveille **exactement ce qui est écrit ici**.

## Règles

1. **La connaissance ne peut pas pourrir** : `npm run check:manifest` (lancé en CI à chaque
   push) échoue si une route, une RPC ou une table citée n'existe plus dans le code — ou si
   une nouvelle route majeure n'est pas mémorisée. Le contrôle **génère le brouillon**
   d'entrée manquante : il ne reste qu'à compléter les invariants métier.
2. **Chaque entrée cite ses sources** (`sources: ["fichier:ligne"]`) — c'est de l'analyse du
   code réel, jamais de mémoire ni d'invention.
3. Les fichiers sont **chargés en base au démarrage du worker leader**
   (`fatome_manifest_upsert` + `fatome_probes_upsert`), jamais édités à la main en base.
4. Toute nouvelle entrée reçoit **automatiquement une sonde de disponibilité** (elle vérifie
   que ses RPC/tables existent vraiment) — badge « sonde par défaut » sur la carte PDG tant
   qu'aucun invariant sur mesure n'est écrit.

## Format (`*.json`)

```jsonc
{
  "features": [
    {
      "feature_key": "vendeur_physique.caisse_vente",   // <interface>.<fonction>
      "interface": "vendeur_physique",
      "label": "Caisse POS — vente comptoir",
      "criticality": "critical",                        // critical | high | normal
      "routes": ["POST /api/pos/sync", "POST /api/pos/order"],
      "rpcs": ["create_pos_sale_complete"],
      "tables": ["pos_sales", "pos_sales.total_amount"], // "table" ou "table.colonne"
      "externals": [],
      "invariants": [
        { "key": "inv:vendeur_physique.caisse_vente:total_coherent",
          "rule": "total = sous-total + taxes − remise (± 0,01)" }
      ],
      "depends_on": ["transversal.wallet"],
      "sources": ["src/routes/pos.routes.ts:1"]
    }
  ],
  "probes": [
    { "probe_key": "inv:vendeur_physique.caisse_vente:total_coherent",
      "feature_key": "vendeur_physique.caisse_vente",
      "probe_kind": "invariant", "label": "Total caisse cohérent", "criticality": "critical" }
  ]
}
```

Les sondes `invariant` nomment une clé **implémentée en SQL** dans
`fatome_probe_check()` (migration `20260807270000`) : aucune config ne porte de SQL —
une table qui contient du SQL exécutable serait une injection.
