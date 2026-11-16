import React, { createContext, useContext, useEffect, useState, useCallback, useRef, ReactNode } from 'react';
import { supabase } from '@/lib/supabase';
import { useAuth } from './AuthContext';
import { Database, UserRole } from '@/types/database.types';

type Organization = Database['public']['Tables']['organizations']['Row'];
type OrgMember = Database['public']['Tables']['organization_members']['Row'];
type OrgSettings = Database['public']['Tables']['organization_settings']['Row'];

interface OrgContextType {
  currentOrg: Organization | null;
  organizations: Organization[];
  membership: OrgMember | null;
  settings: OrgSettings | null;
  role: UserRole | null;
  loading: boolean;
  switchOrg: (orgId: string) => void;
  refreshOrgs: () => Promise<void>;
  isOwnerOrAdmin: boolean;
  canManageSales: boolean;
  canManagePurchases: boolean;
  formatCurrency: (amount: number) => string;
}

const OrgContext = createContext<OrgContextType | undefined>(undefined);

export const OrgProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const { user } = useAuth();
  const userId = user?.id ?? null;
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [currentOrg, setCurrentOrg] = useState<Organization | null>(null);
  const [membership, setMembership] = useState<OrgMember | null>(null);
  const [settings, setSettings] = useState<OrgSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const lastLoadedUserId = useRef<string | null>(null);

  const fetchOrgDetails = useCallback(async (orgId: string, userId: string) => {
    try {
      // 1. Fetch Membership
      const { data: memberData } = await supabase
        .from('organization_members')
        .select('*')
        .eq('organization_id', orgId)
        .eq('user_id', userId)
        .single();

      if (memberData) {
        setMembership(memberData);
      }

      // 2. Fetch Settings
      const { data: settingsData } = await supabase
        .from('organization_settings')
        .select('*')
        .eq('organization_id', orgId)
        .single();

      if (settingsData) {
        setSettings(settingsData);
      }
    } catch (err) {
      console.error('Error fetching organization details:', err);
    }
  }, []);

  const refreshOrgs = useCallback(async () => {
    if (!userId) {
      setOrganizations([]);
      setCurrentOrg(null);
      setMembership(null);
      setSettings(null);
      lastLoadedUserId.current = null;
      setLoading(false);
      return;
    }

    try {
      // Keep the current app visible during background or explicit refreshes.
      // Only show the full-screen loader for first load or user changes.
      if (lastLoadedUserId.current !== userId) setLoading(true);
      // Fetch organizations where user is an active member
      const { data: memberRows, error: memberErr } = await supabase
        .from('organization_members')
        .select('organization_id, role')
        .eq('user_id', userId)
        .eq('is_active', true);

      if (memberErr || !memberRows || memberRows.length === 0) {
        setOrganizations([]);
        setCurrentOrg(null);
        setMembership(null);
        setSettings(null);
        setLoading(false);
        return;
      }

      const orgIds = memberRows.map((m) => m.organization_id);
      const { data: orgsData, error: orgsErr } = await supabase
        .from('organizations')
        .select('*')
        .in('id', orgIds)
        .eq('is_active', true);

      if (orgsErr || !orgsData) {
        setOrganizations([]);
        setCurrentOrg(null);
        setMembership(null);
        setSettings(null);
        setLoading(false);
        return;
      }

      setOrganizations(orgsData);

      // Select active org from localStorage or default to first
      const savedOrgId = localStorage.getItem('shopflow_active_org_id');
      const active = orgsData.find((o) => o.id === savedOrgId) || orgsData[0];

      if (active) {
        setCurrentOrg(active);
        localStorage.setItem('shopflow_active_org_id', active.id);
        await fetchOrgDetails(active.id, userId);
      }
    } catch (err) {
      console.error('Error refreshing organizations:', err);
    } finally {
      lastLoadedUserId.current = userId;
      setLoading(false);
    }
  }, [userId, fetchOrgDetails]);

  useEffect(() => {
    refreshOrgs();
  }, [refreshOrgs]);

  const switchOrg = (orgId: string) => {
    const target = organizations.find((o) => o.id === orgId);
    if (target && user) {
      setCurrentOrg(target);
      localStorage.setItem('shopflow_active_org_id', target.id);
      fetchOrgDetails(target.id, user.id);
    }
  };

  const role = membership?.role ?? null;
  const isOwnerOrAdmin = role === 'owner' || role === 'admin';
  const canManageSales = ['owner', 'admin', 'manager', 'staff'].includes(role || '');
  const canManagePurchases = ['owner', 'admin', 'manager'].includes(role || '');

  const formatCurrency = useCallback((amount: number): string => {
    const symbol = settings?.currency_symbol || 'Ks';
    return `${Number(amount || 0).toLocaleString()} ${symbol}`;
  }, [settings?.currency_symbol]);

  return (
    <OrgContext.Provider
      value={{
        currentOrg,
        organizations,
        membership,
        settings,
        role,
        loading,
        switchOrg,
        refreshOrgs,
        isOwnerOrAdmin,
        canManageSales,
        canManagePurchases,
        formatCurrency,
      }}
    >
      {children}
    </OrgContext.Provider>
  );
};

export const useOrg = (): OrgContextType => {
  const context = useContext(OrgContext);
  if (!context) {
    throw new Error('useOrg must be used within an OrgProvider');
  }
  return context;
};

