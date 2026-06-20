// src/config/load-env.ts
import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const envPath = path.resolve(__dirname, '../../.env');
console.log('DEBUG: process.cwd() =', process.cwd());
console.log('DEBUG: dotenv path =', envPath);
dotenv.config({ path: envPath });
