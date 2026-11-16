import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';

export interface OrganizationEntitlement {
  feature_key: string;
  feature_name: string;
  feature_type: 'boolean' | 'limit' | 'numeric' | 'text';
  category: string;
  is_allowed: boolean;
  reason: string;
  current_usage: number | null;
  limit_value: number | null;
  remaining_usage: number | null;
  subscription_status: string;
}

export const useEntitlements = () => {
  const { currentOrg } = useOrg();
  const orgId = currentOrg?.id;
  return useQuery({
    queryKey: ['organization_entitlements', orgId],
    enabled: Boolean(orgId),
    queryFn: async (): Promise<OrganizationEntitlement[]> => {
      if (!orgId) return [];
      const { data, error } = await supabase.rpc('get_organization_entitlements', { p_org_id: orgId });
      if (error) throw error;
      return (data ?? []) as OrganizationEntitlement[];
    },
    staleTime: 30_000,
  });
};
