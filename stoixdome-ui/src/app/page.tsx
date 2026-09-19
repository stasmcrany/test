'use client'

import { useMemo, useState } from 'react'
import {
  unresolvedAccessContext,
  type AccessContextPresentation,
} from '@/lib/access-context'

type WorkspaceSection = 'attention' | 'cases' | 'environments'

interface SectionDefinition {
  id: WorkspaceSection
  label: string
  title: string
  description: string
}

const sections: readonly SectionDefinition[] = [
  {
    id: 'attention',
    label: 'Внимание',
    title: 'Внимание',
    description:
      'Здесь появятся только случаи, которые требуют внимания, проверки или решения.',
  },
  {
    id: 'cases',
    label: 'Дела',
    title: 'Дела',
    description:
      'Рабочее пространство Case: что произошло, что известно, что предлагается и что получилось.',
  },
  {
    id: 'environments',
    label: 'Среды',
    title: 'Среды',
    description:
      'Read-only состояние подключённых сред, свежесть наблюдений и переход к объектам.',
  },
]

function AccessContextBadge({
  context,
}: {
  context: AccessContextPresentation
}) {
  const status =
    context.availability === 'AVAILABLE'
      ? 'Доступ подтверждён'
      : context.availability === 'UNAVAILABLE'
        ? 'Доступ недоступен'
        : 'Контекст доступа ещё не подключён'

  return (
    <div className="access-context" aria-label="Контекст доступа">
      <span className="access-dot" data-state={context.availability} />
      <div>
        <strong>{status}</strong>
        <span>{context.displayLabel}</span>
      </div>
    </div>
  )
}

export default function Home() {
  const [activeSection, setActiveSection] =
    useState<WorkspaceSection>('attention')

  const active = useMemo(
    () => sections.find((section) => section.id === activeSection) ?? sections[0],
    [activeSection],
  )

  return (
    <main className="workspace-shell">
      <header className="workspace-topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">X</span>
          <div>
            <strong>stoiXDome</strong>
            <span>STOIXLAB</span>
          </div>
        </div>

        <AccessContextBadge context={unresolvedAccessContext} />
      </header>

      <div className="workspace-layout">
        <aside className="workspace-nav" aria-label="Основная навигация">
          <div className="nav-caption">Workspace</div>
          {sections.map((section) => (
            <button
              className="nav-item"
              data-active={activeSection === section.id}
              key={section.id}
              onClick={() => setActiveSection(section.id)}
              type="button"
            >
              <span>{section.label}</span>
              {section.id === 'attention' ? (
                <span className="nav-count" aria-label="Нет новых элементов">0</span>
              ) : null}
            </button>
          ))}
        </aside>

        <section className="workspace-content" aria-live="polite">
          <div className="content-heading">
            <div>
              <span className="eyebrow">Production-v1 workspace</span>
              <h1>{active.title}</h1>
              <p>{active.description}</p>
            </div>

            <div className="system-state">
              <span className="state-label">Read model</span>
              <strong>Ожидает подключение projection adapter</strong>
            </div>
          </div>

          <div className="empty-state">
            <div className="empty-icon" aria-hidden="true">◎</div>
            <h2>Безопасная Product UI поверхность готовится к данным</h2>
            <p>
              Этот shell не создаёт факты, решения, entitlement, исполнение или
              outcome. Он только отображает данные canonical read-plane.
            </p>
          </div>
        </section>
      </div>
    </main>
  )
}
