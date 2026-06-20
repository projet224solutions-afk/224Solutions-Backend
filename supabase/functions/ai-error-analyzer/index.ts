import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { error, context } = await req.json();

    if (!error) {
      return new Response(
        JSON.stringify({ error: 'Error data is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY not configured');
    }

    // Préparer le contexte pour l'IA
    const systemPrompt = `Tu es un expert en debugging et correction automatique pour 224SOLUTIONS.

Ton rôle est d'analyser les erreurs système et de proposer des solutions concrètes et actionnables.

Contexte de l'erreur:
- Module: ${error.module || 'unknown'}
- Type: ${error.error_type || 'unknown'}
- Message: ${error.error_message || 'No message'}
- Sévérité: ${error.severity || 'unknown'}
- Stack: ${error.stack_trace || 'No stack trace'}

${context ? `Contexte additionnel:\n${JSON.stringify(context, null, 2)}` : ''}

Analyse l'erreur et fournis:
1. Une explication claire de la cause
2. L'impact potentiel sur le système
3. Des étapes de correction concrètes
4. Une priorisation (critique/haute/moyenne/basse)
5. Si possible, du code pour corriger automatiquement

Réponds en JSON avec cette structure:
{
  "cause": "Explication de la cause",
  "impact": "Impact sur le système",
  "priority": "critical|high|medium|low",
  "autoFixable": true/false,
  "steps": ["étape 1", "étape 2", ...],
  "code": "Code de correction si autoFixable",
  "prevention": "Comment prévenir cette erreur"
}`;

    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: 'Analyse cette erreur et propose une solution.' }
        ],
        temperature: 0.3,
        max_tokens: 1000
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('AI Gateway error:', response.status, errorText);
      throw new Error(`AI Gateway error: ${response.status}`);
    }

    const data = await response.json();
    const content = data.choices?.[0]?.message?.content || '{}';

    // Parser la réponse JSON de l'IA
    let analysis;
    try {
      // Extraire le JSON si l'IA a ajouté du texte autour
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      analysis = jsonMatch ? JSON.parse(jsonMatch[0]) : JSON.parse(content);
    } catch (e) {
      console.error('Failed to parse AI response:', content);
      analysis = {
        cause: 'Analyse non disponible',
        impact: 'Impact inconnu',
        priority: 'medium',
        autoFixable: false,
        steps: ['Vérifier manuellement le système'],
        prevention: 'Surveillance accrue recommandée'
      };
    }

    // Enregistrer l'analyse dans la base
    await supabaseClient
      .from('system_errors')
      .update({
        metadata: {
          ...error.metadata,
          ai_analysis: analysis,
          analyzed_at: new Date().toISOString()
        }
      })
      .eq('id', error.id);

    // Si auto-fixable, créer ou mettre à jour un auto-fix
    if (analysis.autoFixable && analysis.code) {
      const { data: existingFix } = await supabaseClient
        .from('auto_fixes')
        .select('*')
        .eq('error_pattern', error.error_type)
        .single();

      if (existingFix) {
        // Mettre à jour le fix existant
        await supabaseClient
          .from('auto_fixes')
          .update({
            fix_description: analysis.steps.join('; '),
            fix_code: analysis.code,
            is_active: true
          })
          .eq('id', existingFix.id);
      } else {
        // Créer un nouveau fix
        await supabaseClient
          .from('auto_fixes')
          .insert({
            error_pattern: error.error_type,
            fix_description: analysis.steps.join('; '),
            fix_type: 'ai_generated',
            fix_code: analysis.code,
            is_active: true,
            times_applied: 0,
            success_rate: 0
          });
      }

      // Créer une alerte si priorité critique ou haute
      if (analysis.priority === 'critical' || analysis.priority === 'high') {
        await supabaseClient
          .from('security_alerts')
          .insert({
            alert_type: 'system_error',
            severity: analysis.priority,
            description: `${error.module}: ${error.error_message}`,
            source: error.module || 'system',
            auto_actions: {
              ai_analysis: analysis,
              error_id: error.id
            }
          });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        analysis,
        timestamp: new Date().toISOString()
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in ai-error-analyzer function:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});
