export type AccessContextAvailability =
  | 'UNRESOLVED'
  | 'AVAILABLE'
  | 'UNAVAILABLE'

export interface AccessContextPresentation {
  availability: AccessContextAvailability
  displayLabel: string
  scopeLabel?: string
  expiresAtLabel?: string
}

/**
 * Presentation-only seam.
 *
 * This is deliberately non-authoritative. Licensing / entitlement semantics
 * are frozen later at LIC-UI-CONVERGENCE-001 and must be supplied by a
 * server-side canonical access-context adapter.
 */
export interface AccessContextProvider {
  read(): Promise<AccessContextPresentation>
}

export const unresolvedAccessContext: AccessContextPresentation = {
  availability: 'UNRESOLVED',
  displayLabel: 'Контекст доступа ожидает согласования',
}
