import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Kuri-App",
  description: "Kuri and Chitty management application",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
