import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import './design/base.css';
import './design/components.css';

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
