import { useCutOffViews } from '../data/store';
import { cutOffMessage } from '../data/cutoff';

// Shown above any page that has loaded a list which was cut off, so a short list is never mistaken for a complete one.
export function CutOffBanner() {
  const message = cutOffMessage(useCutOffViews());
  if (!message) return null;
  return <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)', marginBottom: 16 }}><b>Not everything is shown.</b> {message}</div>;
}
