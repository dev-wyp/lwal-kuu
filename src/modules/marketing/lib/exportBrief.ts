import type { MarketingContent } from '../types';

export function buildTrialTrackingUrl(
  origin: string,
  content: Pick<MarketingContent, 'id' | 'platform' | 'campaign_id'>
): string {
  const url = new URL('/register', origin);
  url.searchParams.set('utm_source', content.platform);
  url.searchParams.set('utm_medium', 'social');
  url.searchParams.set('utm_campaign', content.campaign_id || 'lwal-kuu-trial');
  url.searchParams.set('utm_content', content.id);
  url.searchParams.set('plan', 'starter');
  return url.toString();
}

export function buildManualPublishBrief(content: MarketingContent, trackingUrl: string): string {
  const scenes = content.video_script?.scenes
    ?.map(
      (scene) =>
        `Scene ${scene.scene} (${scene.duration_seconds}s)\nVisual: ${scene.visual}\nOn-screen: ${scene.on_screen_text}\nVO: ${scene.voice_over}`
    )
    .join('\n\n');

  return [
    'Lwal Kuu manual publishing brief',
    `Timezone: Asia/Yangon`,
    `Status: ${content.status} (do not post unless approved or scheduled)`,
    `Platform: ${content.platform}`,
    `Type: ${content.content_type}`,
    `Pillar: ${content.content_pillar}`,
    `Title: ${content.title}`,
    '',
    'Hook',
    content.hook || '(none)',
    '',
    'Caption',
    content.caption,
    '',
    `CTA: ${content.cta || '(none)'}`,
    `Hashtags: ${(content.hashtags || []).join(' ')}`,
    '',
    'Trial tracking link (paste in bio/button)',
    trackingUrl,
    '',
    'Image / design prompt',
    content.image_prompt || '(none)',
    '',
    'Video production brief',
    content.production_brief || '(none)',
    '',
    content.video_script ? `Opening hook: ${content.video_script.opening_hook}` : '',
    scenes || '',
    '',
    'Instructions: Post only after owner approval. Do not invent testimonials, stats, or unlisted Lwal Kuu features.',
  ]
    .filter((line) => line !== '')
    .join('\n');
}

export function downloadTextFile(filename: string, contents: string): void {
  const blob = new Blob([contents], { type: 'text/plain;charset=utf-8' });
  const href = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = href;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(href);
}
