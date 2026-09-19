import './globals.css'

export const metadata = {
  title: 'stoiXDome',
  description: 'STOIXLAB governed assurance workspace',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="ru" suppressHydrationWarning>
      <body>{children}</body>
    </html>
  )
}
