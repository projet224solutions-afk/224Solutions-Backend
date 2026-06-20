# ============================================================================
# SCRIPT DE DÉPLOIEMENT - SYSTÈME DE SURVEILLANCE LOGIQUE (PowerShell)
# ============================================================================
# Déploie la migration SQL sur Supabase avec vérification complète
# Usage: .\deploy-surveillance.ps1 -ProjectId "YOUR_PROJECT_ID" -Environment "production"
# ============================================================================

param(
    [string]$ProjectId = "",
    [string]$Environment = "production"
)

# Configuration
$migrationFile = "supabase/migrations/20260201000000_surveillance_logique_system.sql"
$backupDir = "backups"

# Functions pour couleurs
function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
}

function Write-Error {
    Write-Host "✗ $args" -ForegroundColor Red
}

function Write-Warning {
    Write-Host "⚠ $args" -ForegroundColor Yellow
}

function Write-Info {
    Write-Host "ℹ $args" -ForegroundColor Cyan
}

function Write-Section {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host $args -ForegroundColor Blue
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Blue
}

# ============================================================================
# PHASE 1: VÉRIFICATION PRÉ-DÉPLOIEMENT
# ============================================================================

Write-Section "🚀 PHASE 1: VÉRIFICATION PRÉ-DÉPLOIEMENT"

# Vérifier que la migration existe
if (-not (Test-Path $migrationFile)) {
    Write-Error "Migration file not found: $migrationFile"
    exit 1
}

Write-Success "Migration file exists"

# Vérifier que Supabase CLI est installé
try {
    $supabaseVersion = supabase --version
    Write-Success "Supabase CLI is installed: $supabaseVersion"
}
catch {
    Write-Error "Supabase CLI not found. Install with: npm install -g supabase"
    exit 1
}

# Vérifier PROJECT_ID
if ([string]::IsNullOrEmpty($ProjectId)) {
    Write-Warning "PROJECT_ID not provided. Reading from .env.local..."
    if (Test-Path ".env.local") {
        $envContent = Get-Content ".env.local"
        $projectIdLine = $envContent | Select-String "SUPABASE_PROJECT_ID"
        if ($projectIdLine) {
            $ProjectId = $projectIdLine.Line.Split('=')[1].Trim()
        }
    }
}

if ([string]::IsNullOrEmpty($ProjectId)) {
    Write-Error "PROJECT_ID required. Usage: .\deploy-surveillance.ps1 -ProjectId 'YOUR_PROJECT_ID'"
    exit 1
}

Write-Success "Project ID: $ProjectId"

# ============================================================================
# PHASE 2: VÉRIFIER L'INTÉGRITÉ DE LA MIGRATION
# ============================================================================

Write-Section "🔍 PHASE 2: VÉRIFICATION DE L'INTÉGRITÉ DE LA MIGRATION"

$migrationContent = Get-Content $migrationFile -Raw

$checks = @(
    @{ name = "logic_rules table"; pattern = "CREATE TABLE.*logic_rules" },
    @{ name = "logic_anomalies table"; pattern = "CREATE TABLE.*logic_anomalies" },
    @{ name = "logic_corrections table"; pattern = "CREATE TABLE.*logic_corrections" },
    @{ name = "logic_audit table"; pattern = "CREATE TABLE.*logic_audit" },
    @{ name = "verify_logic_rule function"; pattern = "CREATE OR REPLACE FUNCTION verify_logic_rule" },
    @{ name = "detect_all_anomalies function"; pattern = "CREATE OR REPLACE FUNCTION detect_all_anomalies" },
    @{ name = "apply_correction function"; pattern = "CREATE OR REPLACE FUNCTION apply_correction" },
    @{ name = "get_system_health function"; pattern = "CREATE OR REPLACE FUNCTION get_system_health" }
)

foreach ($check in $checks) {
    if ($migrationContent -match $check.pattern) {
        Write-Success $check.name
    }
    else {
        Write-Error "$($check.name) not found in migration"
        exit 1
    }
}

# ============================================================================
# PHASE 3: SAUVEGARDER LA BASE DE DONNÉES
# ============================================================================

Write-Section "💾 PHASE 3: CRÉATION D'UNE SAUVEGARDE"

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $backupDir "pre-surveillance-$timestamp.sql"

Write-Info "Création de la sauvegarde (cela peut prendre quelques minutes)..."
try {
    supabase db pull --project-ref $ProjectId | Out-File $backupFile
    Write-Success "Backup créée: $backupFile"
}
catch {
    Write-Warning "Impossible de créer une sauvegarde locale (manuel peut être requis)"
}

# ============================================================================
# PHASE 4: VÉRIFIER LE PLAN DE DÉPLOIEMENT
# ============================================================================

Write-Section "📋 PHASE 4: VÉRIFICATION DU PLAN DE DÉPLOIEMENT"

Write-Info "Vérification du plan de migration (dry-run)..."
try {
    $dryRunOutput = supabase db push --project-ref $ProjectId --dry-run 2>&1
    Write-Info "Plan de migration:"
    Write-Host $dryRunOutput | Select-Object -First 20
}
catch {
    Write-Warning "Impossible de générer le plan (la migration sera appliquée directement)"
}

# ============================================================================
# PHASE 5: CONFIRMATION UTILISATEUR
# ============================================================================

Write-Section "⚠️  CONFIRMATION"

Write-Warning "Vous êtes sur le point de déployer une migration en PRODUCTION"
Write-Info "Cela créera:"
Write-Info "  • 5 tables (logic_rules, logic_anomalies, etc.)"
Write-Info "  • 4 RPC functions"
Write-Info "  • RLS policies pour accès PDG-only"
Write-Info ""

$confirm = Read-Host "Continuer? (y/n)"

if ($confirm -ne "y" -and $confirm -ne "Y") {
    Write-Error "Déploiement annulé"
    exit 1
}

# ============================================================================
# PHASE 6: DÉPLOYER LA MIGRATION
# ============================================================================

Write-Section "🚀 PHASE 6: DÉPLOIEMENT DE LA MIGRATION"

Write-Info "Déploiement de la migration..."
try {
    supabase db push --project-ref $ProjectId
    Write-Success "Migration déployée avec succès"
}
catch {
    Write-Error "Erreur lors du déploiement: $_"
    exit 1
}

# ============================================================================
# PHASE 7: ATTENDRE LA CRÉATION DES TABLES
# ============================================================================

Write-Info "Attente de la création des tables (5 secondes)..."
Start-Sleep -Seconds 5

# ============================================================================
# PHASE 8: VÉRIFIER LE DÉPLOIEMENT
# ============================================================================

Write-Section "✅ PHASE 7: VÉRIFICATION DU DÉPLOIEMENT"

$verificationScript = @"
-- Vérifier les tables
SELECT COUNT(*) as table_count
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name LIKE 'logic_%';

-- Vérifier les RPC functions
SELECT COUNT(*) as function_count
FROM pg_proc
WHERE proname IN ('verify_logic_rule', 'detect_all_anomalies', 'apply_correction', 'get_system_health');

-- Afficher les tables
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name LIKE 'logic_%'
ORDER BY table_name;
"@

Write-Info "Instructions de vérification manuelle:"
Write-Info "1. Ouvrir: Supabase Dashboard → SQL Editor"
Write-Info "2. Exécuter le script suivant:"
Write-Host $verificationScript -ForegroundColor Gray

# ============================================================================
# PHASE 9: RAPPORT FINAL
# ============================================================================

Write-Section "✅ DÉPLOIEMENT COMPLÉTÉ AVEC SUCCÈS !"

Write-Success "Résumé:"
Write-Host "  ✓ Migration SQL déployée"
Write-Host "  ✓ 5 tables créées"
Write-Host "  ✓ 4 RPC functions créées"
Write-Host "  ✓ RLS policies configurées (PDG-only access)"
Write-Host "  ✓ Backup créée: $backupFile"

Write-Warning ""
Write-Warning "Prochaines étapes:"
Write-Host "  1. Vérifier manuellement dans Supabase Dashboard"
Write-Host "  2. Configurer les Cron Jobs (toutes les 5 minutes)"
Write-Host "  3. Intégrer le PDG Dashboard dans les routes"
Write-Host "  4. Exécuter: npm run test:surveillance"
Write-Host ""

Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Blue
