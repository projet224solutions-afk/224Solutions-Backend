// Déclaration de types minimale pour `speakeasy` (paquet JS sans @types installé).
// Couvre uniquement l'API utilisée par totpMfa.service.ts.
declare module 'speakeasy' {
  interface GeneratedSecret {
    ascii: string;
    hex: string;
    base32: string;
    otpauth_url?: string;
  }
  interface GenerateSecretOptions {
    length?: number;
    name?: string;
    issuer?: string;
    symbols?: boolean;
  }
  interface TotpVerifyOptions {
    secret: string;
    encoding?: 'ascii' | 'hex' | 'base32';
    token: string;
    window?: number;
    step?: number;
    time?: number;
  }
  interface OtpauthURLOptions {
    secret: string;
    label: string;
    issuer?: string;
    encoding?: 'ascii' | 'hex' | 'base32';
    algorithm?: string;
    digits?: number;
    period?: number;
  }
  export function generateSecret(options?: GenerateSecretOptions): GeneratedSecret;
  export const totp: {
    verify(options: TotpVerifyOptions): boolean;
    (options: any): string;
  };
  export function otpauthURL(options: OtpauthURLOptions): string;
  const _default: {
    generateSecret: typeof generateSecret;
    totp: typeof totp;
    otpauthURL: typeof otpauthURL;
  };
  export default _default;
}
