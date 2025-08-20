// Simple authentication hook combining MSAL React hooks
'use client';

import { useCallback } from 'react';
import { 
  useMsal,
  useIsAuthenticated
} from '@azure/msal-react';
import { InteractionStatus } from '@azure/msal-browser';
import { tokenRequest } from '../lib/auth/msal-config';

export function useAuth() {
  const { instance, inProgress } = useMsal();
  const isAuthenticated = useIsAuthenticated();

  const getAccessToken = useCallback(async () => {
    const activeAccount = instance.getActiveAccount();
    
    if (!isAuthenticated || inProgress !== InteractionStatus.None || !activeAccount) {
      return null;
    }
    
    try {
      const response = await instance.acquireTokenSilent({
        ...tokenRequest,
        account: activeAccount
      });
      return response?.accessToken || null;
    } catch {
      return null;
    }
  }, [instance, isAuthenticated, inProgress]);

  const login = useCallback(async () => {
    try {
      const response = await instance.loginPopup(tokenRequest);
      instance.setActiveAccount(response.account);
      return response;
    } catch (error) {
      throw error;
    }
  }, [instance]);

  return {
    isAuthenticated,
    isLoading: inProgress !== InteractionStatus.None,
    error: null, // We'll handle errors in the individual functions
    login,
    logout: () => instance.logoutPopup(),
    getAccessToken,
    user: instance.getActiveAccount(),
  };
}
