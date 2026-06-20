# Script PowerShell pour exécuter la migration SQL sur Supabase PostgreSQL

$host = "db.uakkxaibujzxdiqzpnpr.supabase.co"
$port = "5432"
$user = "postgres"
$password = $env:SUPABASE_DB_PASSWORD
$dbname = "postgres"
$sqlFile = "d:\224Solutions\supabase\migrations\20260105020000_agent_commission_stripe_integration.sql"

if ([string]::IsNullOrWhiteSpace($password)) {
	throw "SUPABASE_DB_PASSWORD is not set. Define it in your environment before running this script."
}

# Définit le mot de passe pour psql
$env:PGPASSWORD = $password

# Exécute la migration
psql -h $host -p $port -U $user -d $dbname -f $sqlFile

# Nettoie la variable d'environnement
Remove-Item Env:PGPASSWORD
