// Authenticated CopilotKit Provider that passes bearer tokens
// Combines MSAL authentication with CopilotKit headers prop

'use client';

import { ReactNode, useState, createContext, useContext, useEffect } from 'react';
import { CopilotKit } from '@copilotkit/react-core';
import { useAuth } from '../hooks/useAuth';
import { getCategoryConfig } from '../lib/categoryConfig';

// Category context for sharing state across components
interface CategoryContextType {
  selectedCategory: string;
  setSelectedCategory: (category: string) => void;
}

const CategoryContext = createContext<CategoryContextType | undefined>(undefined);

export function useCategoryContext() {
  const context = useContext(CategoryContext);
  if (context === undefined) {
    throw new Error('useCategoryContext must be used within a CategoryProvider');
  }
  return context;
}

interface AuthenticatedCopilotProviderProps {
  children: ReactNode;
  runtimeUrl?: string;
}

export function AuthenticatedCopilotProvider({ 
  children, 
  runtimeUrl = '/api/copilotkit' 
}: AuthenticatedCopilotProviderProps) {
  const { isAuthenticated, isLoading, login, getAccessToken } = useAuth();
  const { defaultCategory } = getCategoryConfig();
  const [selectedCategory, setSelectedCategory] = useState<string>(defaultCategory);
  const [accessToken, setAccessToken] = useState<string | null>(null);

  // Get access token when authenticated
  useEffect(() => {
    if (isAuthenticated && !isLoading) {
      getAccessToken().then((token) => {
        setAccessToken(token);
      });
    } else {
      setAccessToken(null);
    }
  }, [isAuthenticated, isLoading, getAccessToken]);

  // Show loading state while authentication is in progress
  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900 mx-auto mb-4"></div>
          <p className="text-gray-600">Authenticating...</p>
        </div>
      </div>
    );
  }

  // Show login prompt if user is not authenticated
  if (!isAuthenticated) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center max-w-md p-8 bg-white rounded-lg shadow-lg">
          <h2 className="text-2xl font-bold text-gray-900 mb-4">
            Sign in Required
          </h2>
          <p className="text-gray-600 mb-6">
            Please sign in to access the chat interface.
          </p>
          <button
            onClick={() => login()}
            disabled={isLoading}
            className="px-6 py-3 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white font-medium rounded-md transition-colors"
          >
            {isLoading ? 'Signing in...' : 'Sign in with Microsoft'}
          </button>
        </div>
      </div>
    );
  }

  // Don't render CopilotKit until we have an access token
  if (!accessToken) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900 mx-auto mb-4"></div>
          <p className="text-gray-600">Initializing secure connection...</p>
        </div>
      </div>
    );
  }

  // Render CopilotKit with authentication headers when user is authenticated
  const headers: Record<string, string> = {
    'Authorization': `Bearer ${accessToken}`
  };
  
  return (
    <CopilotKit
      runtimeUrl={runtimeUrl}
      agent="chat_agent"
      showDevConsole={true}
      properties={{
        threadMetadata: {
          category: selectedCategory,
          timestamp: Date.now()
        }
      }}
      headers={headers}
    >
      <CategoryContext.Provider value={{ selectedCategory, setSelectedCategory }}>
        {children}
      </CategoryContext.Provider>
    </CopilotKit>
  );
}
