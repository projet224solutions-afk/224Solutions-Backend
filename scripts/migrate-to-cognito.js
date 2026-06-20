#!/usr/bin/env node

/**
 * 🔄 SCRIPT DE MIGRATION: Supabase Auth → AWS Cognito
 * 
 * Usage:
 *   1. Configurer les variables d'environnement (voir .env.migration.example)
 *   2. npm install @aws-sdk/client-cognito-identity-provider node-fetch
 *   3. node scripts/migrate-to-cognito.js
 * 
 * Ce script:
 *   - Exporte les utilisateurs depuis Supabase via l'Edge Function
 *   - Crée chaque utilisateur dans AWS Cognito
 *   - Assigne les rôles via custom:role
 *   - Génère un rapport de migration
 * 
 * ⚠️ Les mots de passe NE SONT PAS migrables (hash bcrypt non exportable)
 *    → Les utilisateurs devront faire "Mot de passe oublié" après migration
 */

import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminUpdateUserAttributesCommand,
} from '@aws-sdk/client-cognito-identity-provider';

// ============================================
// CONFIGURATION
// ============================================
const CONFIG = {
  // Supabase
  SUPABASE_URL: process.env.SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
  EDGE_FUNCTION_URL: process.env.SUPABASE_URL + '/functions/v1/export-users-for-cognito',

  // AWS Cognito
  AWS_REGION: process.env.AWS_COGNITO_REGION || 'us-east-1',
  COGNITO_USER_POOL_ID: process.env.AWS_COGNITO_USER_POOL_ID,

  // Migration options
  DRY_RUN: process.env.DRY_RUN === 'true',
  BATCH_SIZE: parseInt(process.env.BATCH_SIZE || '10'),
  DELAY_MS: parseInt(process.env.DELAY_MS || '500'),
};

// Valider la config
function validateConfig() {
  const required = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'COGNITO_USER_POOL_ID'];
  const missing = required.filter(key => !CONFIG[key]);
  if (missing.length > 0) {
    console.error('❌ Variables manquantes:', missing.join(', '));
    console.error('   Voir scripts/.env.migration.example');
    process.exit(1);
  }
}

// ============================================
// COGNITO CLIENT
// ============================================
const cognitoClient = new CognitoIdentityProviderClient({
  region: CONFIG.AWS_REGION,
});

// ============================================
// EXPORT DEPUIS SUPABASE
// ============================================
async function exportUsersFromSupabase() {
  console.log('📥 Export des utilisateurs depuis Supabase...');
  
  let allUsers = [];
  let page = 1;
  let hasMore = true;

  while (hasMore) {
    const response = await fetch(
      `${CONFIG.EDGE_FUNCTION_URL}?page=${page}&per_page=100`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${CONFIG.SUPABASE_SERVICE_ROLE_KEY}`,
          'Content-Type': 'application/json',
        },
      }
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Export failed (${response.status}): ${errText}`);
    }

    const data = await response.json();
    allUsers = allUsers.concat(data.users);
    hasMore = data.has_more;
    page++;

    console.log(`   Page ${page - 1}: ${data.users.length} utilisateurs (total: ${allUsers.length})`);
  }

  return allUsers;
}

// ============================================
// IMPORT DANS COGNITO
// ============================================
async function createCognitoUser(user) {
  const userAttributes = [
    { Name: 'email', Value: user.email },
    { Name: 'email_verified', Value: String(user.email_verified) },
    { Name: 'custom:role', Value: user.role || 'client' },
    { Name: 'custom:supabase_id', Value: user.supabase_id },
  ];

  if (user.full_name) {
    userAttributes.push({ Name: 'name', Value: user.full_name });
  }
  if (user.phone) {
    userAttributes.push({ Name: 'phone_number', Value: user.phone });
  }

  try {
    const command = new AdminCreateUserCommand({
      UserPoolId: CONFIG.COGNITO_USER_POOL_ID,
      Username: user.email,
      UserAttributes: userAttributes,
      // Envoyer un email de bienvenue avec lien pour définir le mot de passe
      DesiredDeliveryMediums: ['EMAIL'],
      // Forcer le reset du mot de passe au premier login
      MessageAction: 'SUPPRESS', // Pas d'email auto, on enverra nous-mêmes
      TemporaryPassword: generateTempPassword(),
    });

    if (CONFIG.DRY_RUN) {
      console.log(`   [DRY RUN] Créerait: ${user.email} (rôle: ${user.role})`);
      return { success: true, dryRun: true };
    }

    const result = await cognitoClient.send(command);

    // Confirmer l'email si vérifié dans Supabase
    if (user.email_verified) {
      await cognitoClient.send(new AdminUpdateUserAttributesCommand({
        UserPoolId: CONFIG.COGNITO_USER_POOL_ID,
        Username: user.email,
        UserAttributes: [
          { Name: 'email_verified', Value: 'true' },
        ],
      }));
    }

    return { success: true, cognitoUsername: result.User?.Username };
  } catch (error) {
    if (error.name === 'UsernameExistsException') {
      return { success: false, error: 'already_exists', email: user.email };
    }
    return { success: false, error: error.message, email: user.email };
  }
}

function generateTempPassword() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%';
  let password = '';
  for (let i = 0; i < 16; i++) {
    password += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return password;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ============================================
// MIGRATION PRINCIPALE
// ============================================
async function migrate() {
  console.log('');
  console.log('🔄 ========================================');
  console.log('   MIGRATION SUPABASE → AWS COGNITO');
  console.log('   ========================================');
  console.log('');

  validateConfig();

  if (CONFIG.DRY_RUN) {
    console.log('⚠️  MODE DRY RUN — aucune modification ne sera effectuée');
    console.log('');
  }

  // 1. Exporter les utilisateurs
  const users = await exportUsersFromSupabase();
  console.log(`\n📊 ${users.length} utilisateurs à migrer`);

  const stats = {
    total: users.length,
    oauth: users.filter(u => u.is_oauth).length,
    email: users.filter(u => !u.is_oauth).length,
    created: 0,
    skipped: 0,
    errors: 0,
    errorDetails: [],
  };

  console.log(`   - ${stats.email} par email/mot de passe`);
  console.log(`   - ${stats.oauth} par OAuth (Google/Facebook)`);
  console.log('');

  // 2. Importer dans Cognito par batch
  for (let i = 0; i < users.length; i += CONFIG.BATCH_SIZE) {
    const batch = users.slice(i, i + CONFIG.BATCH_SIZE);
    console.log(`📦 Batch ${Math.floor(i / CONFIG.BATCH_SIZE) + 1}/${Math.ceil(users.length / CONFIG.BATCH_SIZE)}`);

    const results = await Promise.all(batch.map(createCognitoUser));

    for (const result of results) {
      if (result.success) {
        stats.created++;
      } else if (result.error === 'already_exists') {
        stats.skipped++;
        console.log(`   ⏭️  Déjà existant: ${result.email}`);
      } else {
        stats.errors++;
        stats.errorDetails.push({ email: result.email, error: result.error });
        console.log(`   ❌ Erreur: ${result.email} — ${result.error}`);
      }
    }

    // Rate limiting
    if (i + CONFIG.BATCH_SIZE < users.length) {
      await sleep(CONFIG.DELAY_MS);
    }
  }

  // 3. Rapport final
  console.log('');
  console.log('📋 ========================================');
  console.log('   RAPPORT DE MIGRATION');
  console.log('   ========================================');
  console.log(`   Total:    ${stats.total}`);
  console.log(`   ✅ Créés:  ${stats.created}`);
  console.log(`   ⏭️  Ignorés: ${stats.skipped}`);
  console.log(`   ❌ Erreurs: ${stats.errors}`);
  console.log('');

  if (stats.errorDetails.length > 0) {
    console.log('   Détails des erreurs:');
    stats.errorDetails.forEach(({ email, error }) => {
      console.log(`     - ${email}: ${error}`);
    });
    console.log('');
  }

  console.log('⚠️  IMPORTANT: Les utilisateurs migrés devront');
  console.log('   réinitialiser leur mot de passe via "Mot de passe oublié"');
  console.log('   car les hashes Supabase ne sont pas exportables.');
  console.log('');

  // Sauvegarder le rapport
  const reportPath = `scripts/migration-report-${new Date().toISOString().split('T')[0]}.json`;
  const fs = await import('fs');
  fs.writeFileSync(reportPath, JSON.stringify(stats, null, 2));
  console.log(`📄 Rapport sauvegardé: ${reportPath}`);
}

// ============================================
// EXÉCUTION
// ============================================
migrate().catch(error => {
  console.error('💥 Migration échouée:', error);
  process.exit(1);
});
