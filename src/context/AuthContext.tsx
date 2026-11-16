import React, { createContext, useContext, useEffect, useState, useCallback, useRef, ReactNode } from 'react';
import { User, Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { Database } from '@/types/database.types';

type Profile = Database['public']['Tables']['profiles']['Row'];

interface AuthContextType {
  user: User | null;
  profile: Profile | null;
  session: Session | null;
  loading: boolean;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const [user, setUser] = useState<User | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const profileRequestId = useRef(0);

  const fetchProfile = useCallback(async (userId: string) => {
    const requestId = ++profileRequestId.current;
    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .single();

      if (!error && data && requestId === profileRequestId.current) {
        setProfile(data);
      }
    } catch (err) {
      console.error('Error fetching profile:', err);
    }
  }, []);

  const refreshProfile = useCallback(async () => {
    if (user?.id) {
      await fetchProfile(user.id);
    }
  }, [user, fetchProfile]);

  useEffect(() => {
    let active = true;
    let currentUserId: string | null = null;
    const profileTimers = new Set<ReturnType<typeof setTimeout>>();

    // Keep this callback synchronous. Supabase auth callbacks run while the
    // client holds its auth lock; making another Supabase request here can
    // block all later requests when the browser tab resumes.
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, nextSession) => {
      const nextUser = nextSession?.user ?? null;
      const nextUserId = nextUser?.id ?? null;

      if (event === 'TOKEN_REFRESHED' && nextUserId === currentUserId) {
        // Tokens change during tab resume, but the signed-in identity and app
        // data have not. Avoid restarting auth/profile/org loading for this.
        setSession(nextSession);
        return;
      }

      const userChanged = currentUserId !== nextUserId;
      currentUserId = nextUserId;
      setSession(nextSession);
      setUser(nextUser);

      if (!nextUser) {
        profileRequestId.current += 1;
        setProfile(null);
      } else {
        if (userChanged) {
          profileRequestId.current += 1;
          setProfile(null);
        }

        // Defer the query until after Supabase has released its auth lock.
        if (event !== 'TOKEN_REFRESHED') {
          const timer = setTimeout(() => {
            profileTimers.delete(timer);
            if (active) void fetchProfile(nextUser.id);
          }, 0);
          profileTimers.add(timer);
        }
      }
      setLoading(false);
    });

    return () => {
      active = false;
      profileTimers.forEach(clearTimeout);
      subscription.unsubscribe();
    };
  }, [fetchProfile]);

  const signOut = async () => {
    await supabase.auth.signOut();
    setUser(null);
    setProfile(null);
    setSession(null);
  };

  return (
    <AuthContext.Provider value={{ user, profile, session, loading, signOut, refreshProfile }}>
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = (): AuthContextType => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};

