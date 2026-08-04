# MODELES_TEXTILE_REPORT

Date : 2026-08-04. Ajout **frontend** (données) : `src/data/serviceOfferingTemplates.ts`.

## Catégorie ajoutée
`impression_textile` — label **« Décoration & Impression textile »** (métier physique très demandé en Guinée :
événements, associations, entreprises, mariages). Ajoutée **sans toucher** aux catégories existantes ni à la logique
(les modèles sont de la donnée pré-remplissant le formulaire « Proposer une prestation »).

## 10 modèles ajoutés
| Modèle | Prix | Type | Durée | icône |
|---|---|---|---|---|
| Personnalisation de t-shirt (1 unité) | 50 000 | fixed | 2 j | 👕 |
| Impression t-shirts en lot (événement/équipe) | à partir de 40 000 | from | 5 j | 🎽 |
| Sérigraphie textile (grande quantité) | sur devis | quote | — | 🖨️ |
| Flocage / marquage (nom, numéro) | 30 000 | fixed | 1 j | 🔢 |
| Broderie personnalisée (logo, texte) | à partir de 60 000 | from | 3 j | 🧵 |
| Polo / casquette personnalisé(e) | 55 000 | fixed | 2 j | 🧢 |
| Tote bag / sac personnalisé | 45 000 | fixed | 2 j | 👜 |
| Impression sur mug / gadget (goodies) | 40 000 | fixed | 2 j | ☕ |
| Pack événement (t-shirts + banderole + goodies) | sur devis | quote | — | 🎉 |
| Design du visuel à imprimer (maquette) | à partir de 75 000 | from | 2 j | 🖌️ |

Chaque modèle : titre, description courte, `category='impression_textile'`,
`categoryLabel='Décoration & Impression textile'`, `priceType`, `unit`, `deliveryDays`, `escrow=true`.

## Vérification
1. La catégorie apparaît dans le sélecteur de modèles de `ServiceOfferingsManager` (chips « 👕 Personnalisation de
   t-shirt », etc.) — les 10 modèles sont proposés. ✓
2. Un tap sur un modèle pré-remplit le formulaire (le prestataire ajuste SON prix) → crée la prestation. ✓ (même
   flux `applyTemplate` que les autres catégories).
3. « Sur devis » (sérigraphie, pack événement) → `priceType='quote'` → badge « Sur devis » + « Demander un devis »,
   **jamais « 0 GNF »/« Payer »** (base_price=0 non affiché comme prix ferme). ✓
4. La prestation s'affiche (page prestataire, proximité, marketplace) avec sa photo — flux inchangé. ✓
5. Non-régression : les 30 modèles existants (IT/bureautique/graphisme/vidéo/audio) **inchangés**.
   `tsc` 0 · `vitest` 274/274 · `build` OK.

**« Catégorie Décoration & Impression textile ajoutée le 2026-08-04. »**
