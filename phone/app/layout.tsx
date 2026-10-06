import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Chef Pocket",
  description: "Your Chef, wherever you are. Capture to-dos and thoughts, synced with Mac.",
  manifest: "/manifest.webmanifest",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/icon.svg",
    shortcut: "/icon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
