import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// Client Supabase avec service_role pour bypasser RLS
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  }
);

// Schéma de validation Zod
const CreateProductSchema = z.object({
  name: z.string()
    .trim()
    .min(1, { message: 'Nom du produit requis' })
    .max(200, { message: 'Nom trop long (max 200 caractères)' }),
  description: z.string()
    .trim()
    .max(5000, { message: 'Description trop longue (max 5000 caractères)' })
    .optional(),
  price: z.number()
    .positive({ message: 'Le prix doit être positif' })
    .max(1000000000, { message: 'Prix trop élevé' }),
  sku: z.string()
    .trim()
    .max(100, { message: 'SKU trop long (max 100 caractères)' })
    .optional(),
  category_id: z.string()
    .uuid({ message: 'category_id doit être un UUID valide' })
    .optional(),
  images: z.array(z.string().url({ message: 'URL image invalide' }))
    .max(10, { message: 'Maximum 10 images' })
    .optional(),
  stock_quantity: z.number()
    .int({ message: 'Quantité doit être un entier' })
    .min(0, { message: 'Quantité ne peut pas être négative' })
    .optional(),
  is_active: z.boolean().optional()
});

interface CreateProductRequest extends z.infer<typeof CreateProductSchema> {}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Get user from auth header
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Missing authorization header');
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', '')
    );

    if (authError || !user) {
      throw new Error('Unauthorized');
    }

    const userId = user.id;
    console.log('Creating product for user:', userId);

    // Check product limit via RPC
    const { data: limitCheck, error: limitError } = await supabase.rpc('check_product_limit', {
      p_user_id: userId
    });

    if (limitError) {
      console.error('Error checking product limit:', limitError);
      throw new Error('Failed to check product limit');
    }

    if (!limitCheck || !limitCheck.can_add) {
      const message = limitCheck?.message || 'Product limit reached';
      console.log('Product limit check failed:', message);
      return new Response(
        JSON.stringify({ 
          error: 'PRODUCT_LIMIT_REACHED',
          message,
          current_count: limitCheck?.current_count,
          max_allowed: limitCheck?.max_allowed
        }),
        { 
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Get vendor_id from profiles
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('vendor_id')
      .eq('user_id', userId)
      .single();

    if (profileError || !profile?.vendor_id) {
      console.error('Vendor profile not found:', profileError);
      throw new Error('Vendor profile not found. Please complete your vendor setup.');
    }

    // Parse et valider avec Zod
    const rawBody = await req.json();
    const validationResult = CreateProductSchema.safeParse(rawBody);
    
    if (!validationResult.success) {
      console.error('❌ Validation échouée:', validationResult.error.errors);
      return new Response(
        JSON.stringify({ 
          error: 'Données invalides',
          code: 'VALIDATION_ERROR',
          details: validationResult.error.errors.map(err => ({
            field: err.path.join('.'),
            message: err.message
          }))
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }
    
    const productData: CreateProductRequest = validationResult.data;
    console.log('✅ Validation réussie - Creating product:', productData.name);

    // Insert product
    const { data: product, error: insertError } = await supabase
      .from('products')
      .insert([{
        vendor_id: profile.vendor_id,
        name: productData.name,
        description: productData.description || '',
        price: productData.price,
        sku: productData.sku || null,
        category_id: productData.category_id || null,
        images: productData.images || [],
        stock_quantity: productData.stock_quantity || 0,
        is_active: productData.is_active !== undefined ? productData.is_active : true,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      }])
      .select()
      .single();

    if (insertError) {
      console.error('Error creating product:', insertError);
      throw new Error(`Failed to create product: ${insertError.message}`);
    }

    console.log('Product created successfully:', product.id);

    return new Response(
      JSON.stringify({ 
        success: true, 
        product,
        message: 'Product created successfully'
      }),
      { 
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('Create product error:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { 
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
