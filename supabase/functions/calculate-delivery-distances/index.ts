import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface DistanceRequest {
  driverLocation: { lat: number; lng: number }
  vendorLocation: { lat: number; lng: number }
  clientLocation: { lat: number; lng: number }
}

interface DistanceResult {
  distanceToVendor: number // km
  distanceVendorToClient: number // km
  totalDistance: number // km
  durationToVendor: number // minutes
  durationVendorToClient: number // minutes
  totalDuration: number // minutes
  estimatedEarnings: number // GNF
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const GOOGLE_MAPS_API_KEY = Deno.env.get('GOOGLE_MAPS_API_KEY')
    
    if (!GOOGLE_MAPS_API_KEY) {
      throw new Error('Google Maps API key not configured')
    }

    const { driverLocation, vendorLocation, clientLocation }: DistanceRequest = await req.json()

    console.log('[calculate-delivery-distances] Calculating distances:', {
      driver: driverLocation,
      vendor: vendorLocation,
      client: clientLocation
    })

    // Calculer distance livreur -> vendeur
    const driverToVendor = await getGoogleMapsDistance(
      driverLocation,
      vendorLocation,
      GOOGLE_MAPS_API_KEY
    )

    // Calculer distance vendeur -> client
    const vendorToClient = await getGoogleMapsDistance(
      vendorLocation,
      clientLocation,
      GOOGLE_MAPS_API_KEY
    )

    const totalDistance = driverToVendor.distance + vendorToClient.distance
    const totalDuration = driverToVendor.duration + vendorToClient.duration

    // Calculer les gains estimés (tarification 224Solutions)
    const basePrice = 5000 // GNF - prix de base
    const pricePerKm = 2000 // GNF par km
    const estimatedEarnings = Math.round(basePrice + (totalDistance * pricePerKm))

    const result: DistanceResult = {
      distanceToVendor: Math.round(driverToVendor.distance * 10) / 10,
      distanceVendorToClient: Math.round(vendorToClient.distance * 10) / 10,
      totalDistance: Math.round(totalDistance * 10) / 10,
      durationToVendor: Math.round(driverToVendor.duration),
      durationVendorToClient: Math.round(vendorToClient.duration),
      totalDuration: Math.round(totalDuration),
      estimatedEarnings
    }

    console.log('[calculate-delivery-distances] Result:', result)

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    })
  } catch (error) {
    console.error('[calculate-delivery-distances] Error:', error)
    
    // Fallback avec calcul Haversine
    try {
      const { driverLocation, vendorLocation, clientLocation }: DistanceRequest = await req.json()
      
      const distanceToVendor = haversineDistance(
        driverLocation.lat, driverLocation.lng,
        vendorLocation.lat, vendorLocation.lng
      )
      
      const distanceVendorToClient = haversineDistance(
        vendorLocation.lat, vendorLocation.lng,
        clientLocation.lat, clientLocation.lng
      )
      
      const totalDistance = distanceToVendor + distanceVendorToClient
      const estimatedEarnings = Math.round(5000 + (totalDistance * 2000))
      
      return new Response(JSON.stringify({
        distanceToVendor: Math.round(distanceToVendor * 10) / 10,
        distanceVendorToClient: Math.round(distanceVendorToClient * 10) / 10,
        totalDistance: Math.round(totalDistance * 10) / 10,
        durationToVendor: Math.round(distanceToVendor * 3), // ~20km/h
        durationVendorToClient: Math.round(distanceVendorToClient * 3),
        totalDuration: Math.round(totalDistance * 3),
        estimatedEarnings,
        fallback: true
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      })
    } catch {
      return new Response(JSON.stringify({ 
        error: error instanceof Error ? error.message : 'Unknown error'
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500
      })
    }
  }
})

async function getGoogleMapsDistance(
  origin: { lat: number; lng: number },
  destination: { lat: number; lng: number },
  apiKey: string
): Promise<{ distance: number; duration: number }> {
  const url = `https://maps.googleapis.com/maps/api/distancematrix/json?origins=${origin.lat},${origin.lng}&destinations=${destination.lat},${destination.lng}&mode=driving&key=${apiKey}`
  
  const response = await fetch(url)
  const data = await response.json()
  
  if (data.status !== 'OK' || !data.rows?.[0]?.elements?.[0]) {
    throw new Error('Google Maps API error: ' + data.status)
  }
  
  const element = data.rows[0].elements[0]
  
  if (element.status !== 'OK') {
    throw new Error('Route not found: ' + element.status)
  }
  
  return {
    distance: element.distance.value / 1000, // Convert meters to km
    duration: element.duration.value / 60 // Convert seconds to minutes
  }
}

function haversineDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371 // Earth radius in km
  const dLat = toRad(lat2 - lat1)
  const dLon = toRad(lon2 - lon1)
  const a = 
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2)
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  return R * c
}

function toRad(deg: number): number {
  return deg * (Math.PI / 180)
}
