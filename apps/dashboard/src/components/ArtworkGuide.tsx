import { href } from '../router';

// A plain-words guide to what happens when an order brings new artwork, for DTF prints and for embroidery, in house and third party. It only describes
// what Flow does today; it changes nothing.
export function ArtworkGuide() {
  return (
    <details className="callout soft" data-testid="artwork-guide">
      <summary><b>What happens to new DTF prints and new embroidery?</b> (in house and third party)</summary>
      <div className="stack" style={{ gap: 10, marginTop: 8 }}>
        <div><b>New DTF print, in house</b>
          <ol style={{ margin: '4px 0 0', paddingLeft: 20 }}>
            <li>On <a href={href('dtf-prints')}>DTF prints</a> (In house menu), tick the orders and press <b>Build DTF order</b>. Flow needs the print file stored first: an order with the file missing says so and links to where to add it.</li>
            <li>The DTF order shows under <b>Waiting to send</b>. Open <a href={href('purchasing/emails')}>Purchasing, Emails</a> and approve its email: that is what sends it to Super Print.</li>
            <li>When the prints arrive, press <b>DTF received…</b> on the <b>Ordered, waiting</b> tab. The prints are then applied on the floor.</li>
          </ol></div>
        <div><b>New DTF print, third party</b>
          <ol style={{ margin: '4px 0 0', paddingLeft: 20 }}>
            <li>The decorator orders and makes their own DTF transfers, so they never go on a DTF order to Super Print.</li>
            <li>They see the placements on their portal (DTF prints), download the files and mark each one <b>in production</b>, then <b>made</b>.</li>
            <li>You can see where every transfer stands on <a href={href('dtf-3pd')}>3PD DTF prints</a>, and confirm one for a decorator if they tell you by phone or email.</li>
          </ol></div>
        <div><b>New embroidery (the same for in house and third party)</b>
          <ol style={{ margin: '4px 0 0', paddingLeft: 20 }}>
            <li>On <a href={href('embroidery')}>Embroidery</a> every embroidery area has a tab for <b>In house</b> or <b>Third party</b>. If the customer has had this logo embroidered before, say <b>we have done this before</b>: no swatch is needed.</li>
            <li>A new logo needs a physical swatch. Print the <b>proof sheet</b>, run the swatch, then email the customer a picture with the <b>swatch email</b> and mark it approved when they sign it off.</li>
            <li>If the stitch file was reworked for the job, DecoNetwork still holds the old one: the design goes on <b>Files to update in DecoNetwork</b> until someone replaces it there by hand and ticks it off.</li>
            <li>On <a href={href('preprod')}>Pre-production</a> a person ticks <b>embroidery checked</b> so the order's light goes green.</li>
          </ol></div>
        <div className="dim">Flow never changes anything in DecoNetwork. Whether an order is in house or third party comes from DecoNetwork's Priority Order flag (read every hour) or from a person marking it on the order.</div>
      </div>
    </details>
  );
}
