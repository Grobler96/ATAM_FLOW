import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Portal } from './Portal';
import '../design/base.css';
import '../design/components.css';
import './signin.css';

createRoot(document.getElementById('root')!).render(<StrictMode><Portal /></StrictMode>);
