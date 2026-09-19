import { fireEvent, render, screen } from '@testing-library/react'
import Home from './page'

describe('Production-v1 workspace shell', () => {
  it('renders the three v1 top-level sections', () => {
    render(<Home />)

    expect(screen.getByRole('button', { name: /Внимание/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Дела' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Среды' })).toBeInTheDocument()
  })

  it('switches sections without navigating to a legacy action surface', () => {
    render(<Home />)

    fireEvent.click(screen.getByRole('button', { name: 'Дела' }))
    expect(screen.getByRole('heading', { level: 1, name: 'Дела' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Среды' }))
    expect(screen.getByRole('heading', { level: 1, name: 'Среды' })).toBeInTheDocument()
  })

  it('keeps access context explicitly unresolved until convergence', () => {
    render(<Home />)

    expect(screen.getByLabelText('Контекст доступа')).toHaveTextContent(
      'Контекст доступа ещё не подключён',
    )
  })
})
