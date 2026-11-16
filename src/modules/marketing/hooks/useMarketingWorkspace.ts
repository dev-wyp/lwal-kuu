import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useOrg } from '@/context/OrgContext';
import { useAuth } from '@/context/AuthContext';
import { mktRpc } from '../lib/db';
import type { MarketingSettings, MarketingWorkspace, SocialAccount } from '../types';

export const MarketingOrganizationContext = React.createContext<string | null>(null);

export function useMarketingWorkspace(organizationIdOverride?: string | null) {
  const { currentOrg, role, isOwnerOrAdmin } = useOrg();
  const { profile } = useAuth();
  const scopedOrgId = React.useContext(MarketingOrganizationContext);
  const orgId = organizationIdOverride ?? scopedOrgId ?? currentOrg?.id;
  const isPlatformAdmin = Boolean(profile?.is_platform_admin);
  const canManageMarketing = isPlatformAdmin || role === 'owner' || role === 'admin' || role === 'manager';
  const canApproveMarketing = canManageMarketing;

  const query = useQuery({
    queryKey: ['marketing_workspace', orgId],
    enabled: Boolean(orgId),
    queryFn: async () => {
      if (!orgId) return null;
      const workspaceId = await mktRpc<string>('ensure_marketing_workspace', { p_org_id: orgId });

      const [{ data: workspace, error: wsError }, { data: settings }, { data: accounts }] = await Promise.all([
        supabase.from('marketing_workspaces').select('*').eq('id', workspaceId).single(),
        supabase.from('marketing_settings').select('*').eq('workspace_id', workspaceId).maybeSingle(),
        supabase.from('social_accounts').select('*').eq('workspace_id', workspaceId),
      ]);

      if (wsError) throw wsError;

      return {
        workspace: workspace as MarketingWorkspace,
        settings: settings as MarketingSettings | null,
        accounts: (accounts || []) as SocialAccount[],
      };
    },
  });

  return {
    orgId,
    ...query,
    canManageMarketing,
    canApproveMarketing,
    isOwnerOrAdmin: isPlatformAdmin || isOwnerOrAdmin,
  };
}
