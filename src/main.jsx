import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './assets/fonts/open-fonts.css';
import App from './App.jsx';
import './styles.css';

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
