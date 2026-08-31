import type { Metadata } from 'next';

import './globals.css';

export const metadata: Metadata = {
  title: 'FieldProof Review',
  description: 'Read-only review console for submitted field inspections.',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
