/**
 * 🧠 EDGE FUNCTION: Smart Recommendations API
 * Endpoints: /home, /similar/:id, /popular, /recently-viewed, /track
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    const url = new URL(req.url)
    const path = url.pathname.replace('/smart-recommendations', '').replace(/^\/+/, '')

    // Get user from JWT if present
    let userId: string | null = null
    const authHeader = req.headers.get('Authorization')
    if (authHeader?.startsWith('Bearer ')) {
      const token = authHeader.replace('Bearer ', '')
      const { data: { user } } = await supabase.auth.getUser(token)
      userId = user?.id || null
    }

    // Route: POST /track
    if (req.method === 'POST' && path === 'track') {
      const body = await req.json()
      const { action_type, product_id, vendor_id, category_id, query, session_id, metadata } = body

      if (!action_type) {
        return new Response(JSON.stringify({ error: 'action_type required' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }

      const { error } = await supabase.from('user_activity').insert({
        user_id: userId,
        session_id: session_id || null,
        product_id: product_id || null,
        vendor_id: vendor_id || null,
        category_id: category_id || null,
        action_type,
        query: query || null,
        metadata: metadata || {},
        device_type: req.headers.get('user-agent')?.includes('Mobi') ? 'mobile' : 'desktop',
      })

      if (error) throw error

      // Update preferences async (fire and forget)
      if (userId && product_id) {
        supabase.rpc('compute_user_preferences', { p_user_id: userId }).catch(() => {})
      }

      return new Response(JSON.stringify({ ok: true }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Route: GET /home
    if (path === 'home' || path === '') {
      const limit = parseInt(url.searchParams.get('limit') || '20')
      const { data, error } = await supabase.rpc('get_smart_recommendations', {
        p_user_id: userId,
        p_limit: limit,
        p_type: 'home'
      })
      if (error) throw error

      return new Response(JSON.stringify(data || []), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Route: GET /popular
    if (path === 'popular') {
      const limit = parseInt(url.searchParams.get('limit') || '16')
      const { data, error } = await supabase.rpc('get_trending_products', { p_limit: limit })
      if (error) throw error

      return new Response(JSON.stringify(data || []), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Route: GET /similar/:productId
    if (path.startsWith('similar/')) {
      const productId = path.replace('similar/', '')
      const limit = parseInt(url.searchParams.get('limit') || '10')
      const { data, error } = await supabase.rpc('get_smart_similar_products', {
        p_product_id: productId,
        p_limit: limit
      })
      if (error) throw error

      return new Response(JSON.stringify(data || []), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Route: GET /recently-viewed
    if (path === 'recently-viewed') {
      if (!userId) {
        return new Response(JSON.stringify([]), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }
      const limit = parseInt(url.searchParams.get('limit') || '12')
      const { data, error } = await supabase.rpc('get_recently_viewed', {
        p_user_id: userId,
        p_limit: limit
      })
      if (error) throw error

      return new Response(JSON.stringify(data || []), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    return new Response(JSON.stringify({ error: 'Not found' }), {
      status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })

  } catch (err) {
    console.error('[smart-recommendations] Error:', err)
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})
