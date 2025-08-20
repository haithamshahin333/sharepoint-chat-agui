"use client";

import { MsalProvider } from '@azure/msal-react';
import { PublicClientApplication, EventType } from '@azure/msal-browser';
import { AuthenticatedCopilotProvider } from "./AuthenticatedCopilotProvider";
import msalConfig from '../lib/auth/msal-config';

// Create MSAL instance (following Microsoft's official pattern)
const msalInstance = new PublicClientApplication(msalConfig);

// Initialize MSAL and set active account (Microsoft's pattern from _app.js)
msalInstance.initialize().then(() => {
  // Account selection logic is app dependent. Adjust as needed for different use cases.
  const accounts = msalInstance.getAllAccounts();
  if (accounts.length > 0) {
    msalInstance.setActiveAccount(accounts[0]);
  }

  // Set active account on successful login
  msalInstance.addEventCallback((event) => {
    if (event.eventType === EventType.LOGIN_SUCCESS && event.payload && 'account' in event.payload) {
      const account = event.payload.account;
      if (account) {
        msalInstance.setActiveAccount(account);
      }
    }
  });
});

interface ClientProvidersProps {
  children: React.ReactNode;
}

export function ClientProviders({ children }: ClientProvidersProps) {
  return (
    <MsalProvider instance={msalInstance}>
      <AuthenticatedCopilotProvider>
        {children}
      </AuthenticatedCopilotProvider>
    </MsalProvider>
  );
}
