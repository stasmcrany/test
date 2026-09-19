/**
 * UI-A1a exact wire mirror for the canonical Decision Assurance Projection V2
 * read-plane. This file mirrors serialized field names and enum values only.
 *
 * It creates no factual, reasoning, recommendation, proposal, verdict,
 * execution, outcome, storage, licensing, tenant, or security authority.
 */

export const DECISION_ASSURANCE_PROJECTION_SCHEMA_VERSION =
  'stoix.decision-assurance.projection.v2' as const

export const DECISION_ASSURANCE_PROJECTION_CONTRACT_VERSION = '2.0' as const

export const DECISION_ASSURANCE_PROJECTION_QUERY_SCHEMA_VERSION =
  'stoix.decision-assurance.projection-query.v1' as const

export const PROJECTION_FACET_SCHEMA_VERSION =
  'stoix.decision-assurance.projection-facet.v1' as const

export const PROJECTION_SOURCE_BINDING_SCHEMA_VERSION =
  'stoix.decision-assurance.projection-source-binding.v1' as const

export type ProjectionAvailabilityV1 =
  | 'AVAILABLE'
  | 'NOT_AVAILABLE'

export type ProjectionLifecycleV1 =
  | 'PERFORMED'
  | 'NOT_PERFORMED'
  | 'NOT_APPLICABLE'
  | 'BLOCKED'

export type ProjectionEvidenceV1 =
  | 'SUFFICIENT'
  | 'INSUFFICIENT_EVIDENCE'
  | 'STALE'
  | 'UNKNOWN'
  | 'CONFLICTING'

export type ProjectionConclusionV1 =
  | 'CONCLUSIVE'
  | 'INCONCLUSIVE'
  | 'NOT_EVALUATED'

export type ProjectionDisclosureV1 =
  | 'DISCLOSED'
  | 'REDACTED'
  | 'BLOCKED'

export interface ProjectionFacetStatusV1Wire {
  availability: ProjectionAvailabilityV1
  lifecycle: ProjectionLifecycleV1
  evidence: ProjectionEvidenceV1
  conclusion: ProjectionConclusionV1
  disclosure: ProjectionDisclosureV1
}

export interface ProjectionSourceBindingV1Wire {
  schema_version: typeof PROJECTION_SOURCE_BINDING_SCHEMA_VERSION
  source_family: string
  source_record_ref: string
  source_schema_version: string
  source_version_ref: string | null
  source_digest: string | null
}

export interface ProjectionFacetV1Wire {
  schema_version: typeof PROJECTION_FACET_SCHEMA_VERSION
  facet_key: string
  facet_schema_version: string
  source_family: string
  source_record_refs: readonly string[]
  lineage_refs: readonly string[]
  status: ProjectionFacetStatusV1Wire
  source_native_status: string | null
  payload_schema: string | null
  payload: Readonly<Record<string, unknown>> | null
  reason_refs: readonly string[]
}

export interface DecisionAssuranceProjectionV2Wire {
  projection_ref: string
  projection_schema_version: typeof DECISION_ASSURANCE_PROJECTION_SCHEMA_VERSION
  projection_contract_version:
    typeof DECISION_ASSURANCE_PROJECTION_CONTRACT_VERSION
  case_ref: string
  run_ref: string
  source_bindings: readonly ProjectionSourceBindingV1Wire[]
  facets: readonly ProjectionFacetV1Wire[]
  projection_unresolved_reason_refs: readonly string[]
}

export interface DecisionAssuranceProjectionQueryV1Wire {
  schema_version:
    typeof DECISION_ASSURANCE_PROJECTION_QUERY_SCHEMA_VERSION
  query_ref: string
  case_ref: string
  run_ref: string
  requested_facet_keys: readonly string[]
  as_of_ref: string | null
  visibility_context_ref: string
  disclosure_policy_ref: string
  accepted_projection_schema_versions: readonly string[]
}
