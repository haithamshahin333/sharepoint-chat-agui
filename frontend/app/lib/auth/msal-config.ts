// MSAL Configuration - Following official GitHub patterns
// Source: https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/initialization.md

import { Configuration, LogLevel } from '@azure/msal-browser';

const msalConfig: Configuration = {
  auth: {
    clientId: process.env.NEXT_PUBLIC_MSAL_CLIENT_ID!,
    authority: `https://login.microsoftonline.com/${process.env.NEXT_PUBLIC_MSAL_TENANT_ID}`,
    redirectUri: typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3000',
    postLogoutRedirectUri: typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3000',
    navigateToLoginRequestUrl: true,
  },
  cache: {
    cacheLocation: "sessionStorage", // Options: "sessionStorage", "localStorage", "memoryStorage"
    storeAuthStateInCookie: false, // Set to true only for IE support
  },
  system: {
    loggerOptions: {
      loggerCallback: (level, message, containsPii) => {
        if (containsPii) return;
        
        switch (level) {
          case LogLevel.Error:
            console.error(`[MSAL Error] ${message}`);
            return;
          case LogLevel.Info:
            console.info(`[MSAL Info] ${message}`);
            return;
          case LogLevel.Verbose:
            console.debug(`[MSAL Debug] ${message}`);
            return;
          case LogLevel.Warning:
            console.warn(`[MSAL Warning] ${message}`);
            return;
        }
      },
      piiLoggingEnabled: false,
    },
    windowHashTimeout: 60000,
    iframeHashTimeout: 6000,
  },
};

// Token request configuration for acquiring access tokens
export const tokenRequest = {
  scopes: [
    "openid", 
    "profile", 
    "email",
    // Your FastAPI backend scope from environment variable
    process.env.NEXT_PUBLIC_API_SCOPE || "api://your-backend-client-id/access_as_user"
  ],
};

export default msalConfig;
