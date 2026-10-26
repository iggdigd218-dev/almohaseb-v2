import { Account, Transaction, Item, Voucher, User, DashboardData, ActivityItem, AuthSession, SyncQueueItem, SyncQueueStats, UserPermission, LicenseInfo, LogoutRequest, Facility, CloudInviteData } from './types';
import { getAuthSession, getActiveFacilityId } from './services/syncQueueService';

const BASE_URL = '/api';

async function request<T>(endpoint: string, options?: RequestInit): Promise<T> {
  const session = getAuthSession();
  const activeFac = getActiveFacilityId();
  const safeHeader = (val?: string, fallback = '') => encodeURIComponent(val || fallback);
  const res = await fetch(`${BASE_URL}${endpoint}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'x-store-id': safeHeader(activeFac || session?.store_id, 'WS-MAIN'),
      'x-facility-id': safeHeader(activeFac || session?.store_id, 'WS-MAIN'),
      'x-user-email': safeHeader(session?.user_email, ''),
      'x-device-id': safeHeader(session?.device_id, 'DEV-LOCAL'),
      ...(options?.headers || {}),
    },
  });

  if (!res.ok) {
    let errorMsg = res.statusText;
    try {
      const data = await res.json();
      if (data.error) errorMsg = data.error;
      if (res.status === 403 && data.error === 'DEVICE_EXPELLED') {
        window.dispatchEvent(new CustomEvent('device-expelled', { detail: data }));
      }
    } catch {
      // ignore
    }
    throw new Error(errorMsg);
  }

  return res.json();
}

export const api = {
  // Facilities & Multi-Establishment Management (إدارة المنشآت والفروع المتعددة)
  getFacilities: () => request<Facility[]>('/facilities'),
  getActiveFacility: () => request<Facility>('/facilities/active'),
  createFacility: (fac: Partial<Facility>) => request<{ ok: boolean; facility: Facility }>('/facilities', { method: 'POST', body: JSON.stringify(fac) }),
  updateFacility: (id: string, fac: Partial<Facility>) => request<{ ok: boolean; facility: Facility }>(`/facilities/${id}`, { method: 'PUT', body: JSON.stringify(fac) }),
  deleteFacility: (id: string) => request<{ ok: boolean; message: string }>(`/facilities/${id}`, { method: 'DELETE' }),
  switchFacility: (facility_id: string) => request<{ ok: boolean; active_facility_id: string; facility: Facility }>('/facilities/switch', { method: 'POST', body: JSON.stringify({ facility_id }) }),

  // Instant Cloud Pairing & Member Join (< 50ms)
  createCloudInvite: (facility_id?: string) => request<CloudInviteData>('/cloud-join/invite', { method: 'POST', body: JSON.stringify({ facility_id }) }),
  joinWithCode: (data: { pin?: string; token?: string; device_name?: string; user_name?: string }) =>
    request<{ ok: boolean; session: AuthSession; facility: Facility }>('/cloud-join/join', { method: 'POST', body: JSON.stringify(data) }),

  // Authentication (Google & Email - Multi-Tenant Sovereign Manager)
  login: (credentials: { email: string; password: string; store_id?: string; device_id?: string; mode?: 'individual' | 'enterprise' }) =>
    request<{ ok: boolean; session: AuthSession }>('/auth/login', {
      method: 'POST',
      body: JSON.stringify(credentials),
    }),

  register: (data: { name: string; email: string; password: string; store_id?: string; role?: string; mode?: 'individual' | 'enterprise'; device_id?: string }) =>
    request<{ ok: boolean; session: AuthSession }>('/auth/register', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  loginWithGoogle: (data: { email?: string; name?: string; mode?: 'individual' | 'enterprise'; store_id?: string; device_id?: string }) =>
    request<{ ok: boolean; session: AuthSession }>('/auth/google', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  updateWorkspaceMode: (data: { mode: 'individual' | 'enterprise'; store_id?: string; user_email?: string }) =>
    request<{ ok: boolean; mode: string }>('/workspace/mode', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  // Sync Queue
  getSyncQueueStats: () => request<SyncQueueStats>('/sync-queue/stats'),
  getPendingSyncQueue: (limit = 20) => request<SyncQueueItem[]>(`/sync-queue/pending?limit=${limit}`),
  updateSyncQueueStatus: (queue_ids: string[], status: 'synced' | 'failed' | 'pending' | 'syncing') =>
    request<{ ok: boolean; updated: number }>('/sync-queue/status', {
      method: 'POST',
      body: JSON.stringify({ queue_ids, status }),
    }),

  // Dashboard
  getDashboard: (facility_id?: string) => {
    const params = new URLSearchParams();
    if (facility_id) params.set('facility_id', facility_id);
    return request<DashboardData>(`/dashboard?${params.toString()}`);
  },

  // Accounts
  getAccounts: (kind?: string, search?: string, facility_id?: string) => {
    const params = new URLSearchParams();
    if (kind) params.set('kind', kind);
    if (search) params.set('search', search);
    if (facility_id) params.set('facility_id', facility_id);
    return request<Account[]>(`/accounts?${params.toString()}`);
  },
  createAccount: (account: Partial<Account>) => request<{ id: number }>('/accounts', { method: 'POST', body: JSON.stringify(account) }),
  updateAccount: (id: number, account: Partial<Account>) => request<{ ok: boolean }>(`/accounts/${id}`, { method: 'PUT', body: JSON.stringify(account) }),
  deleteAccount: (id: number) => request<{ ok: boolean }>(`/accounts/${id}`, { method: 'DELETE' }),

  // Transactions
  getTransactions: (type?: string, account_id?: number, facility_id?: string) => {
    const params = new URLSearchParams();
    if (type) params.set('type', type);
    if (account_id) params.set('account_id', String(account_id));
    if (facility_id) params.set('facility_id', facility_id);
    return request<Transaction[]>(`/transactions?${params.toString()}`);
  },
  createTransaction: (tx: Partial<Transaction> & { items?: any[] }) => request<{ id: number }>('/transactions', { method: 'POST', body: JSON.stringify(tx) }),
  deleteTransaction: (id: number) => request<{ ok: boolean }>(`/transactions/${id}`, { method: 'DELETE' }),

  // Items / Inventory
  getItems: () => request<Item[]>('/items'),
  createItem: (item: Partial<Item>) => request<{ id: number }>('/items', { method: 'POST', body: JSON.stringify(item) }),
  updateItem: (id: number, item: Partial<Item>) => request<{ ok: boolean }>(`/items/${id}`, { method: 'PUT', body: JSON.stringify(item) }),
  deleteItem: (id: number) => request<{ ok: boolean }>(`/items/${id}`, { method: 'DELETE' }),

  // Vouchers
  getVouchers: () => request<Voucher[]>('/vouchers'),
  createVoucher: (voucher: Partial<Voucher>) => request<{ id: number }>('/vouchers', { method: 'POST', body: JSON.stringify(voucher) }),
  deleteVoucher: (id: number) => request<{ ok: boolean }>(`/vouchers/${id}`, { method: 'DELETE' }),

  // Users
  getUsers: () => request<User[]>('/users'),
  createUser: (user: Partial<User>) => request<{ id: number }>('/users', { method: 'POST', body: JSON.stringify(user) }),
  updateUser: (id: number, user: Partial<User>) => request<{ ok: boolean }>(`/users/${id}`, { method: 'PUT', body: JSON.stringify(user) }),
  deleteUser: (id: number) => request<{ ok: boolean }>(`/users/${id}`, { method: 'DELETE' }),

  // User Permissions (RBAC)
  getUserPermissions: () => request<UserPermission[]>('/user-permissions'),
  getMyPermissions: () => request<UserPermission>('/user-permissions/me'),
  saveUserPermissions: (data: Partial<UserPermission>) => request<{ ok: boolean; permission: UserPermission }>('/user-permissions', { method: 'POST', body: JSON.stringify(data) }),
  updateUserPermissions: (email: string, data: Partial<UserPermission>) => request<{ ok: boolean; permission: UserPermission }>(`/user-permissions/${encodeURIComponent(email)}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteUserPermissions: (email: string) => request<{ ok: boolean }>(`/user-permissions/${encodeURIComponent(email)}`, { method: 'DELETE' }),

  // Settings
  getSettings: () => request<Record<string, string>>('/settings'),
  saveSettings: (settings: Record<string, string>) => request<{ ok: boolean }>('/settings', { method: 'POST', body: JSON.stringify(settings) }),

  // Activity & Backup
  getActivity: () => request<ActivityItem[]>('/activity'),
  getBackup: () => request<any>('/backup/export'),
  restoreBackup: (backup: any) => request<{ ok: boolean; message: string }>('/backup/restore', { method: 'POST', body: JSON.stringify(backup) }),
  triggerAutoSnapshot: (options: { google_drive?: boolean; email?: string }) => request<{ ok: boolean; snapshot: any }>('/backup/auto-snapshot', { method: 'POST', body: JSON.stringify(options) }),

  // License & Plan
  getLicenseInfo: () => request<LicenseInfo>('/license/info'),

  // Secured Logout Flow & Approvals
  getLogoutRequests: () => request<LogoutRequest[]>('/logout-requests'),
  submitLogoutRequest: (data: { user_email: string; user_name: string; role: string; device_id: string }) =>
    request<{ ok: boolean; id: string; status: string }>('/logout-requests', {
      method: 'POST',
      body: JSON.stringify(data),
    }),
  respondLogoutRequest: (id: string, action: 'approved' | 'rejected') =>
    request<{ ok: boolean; status: string }>(`/logout-requests/${id}/respond`, {
      method: 'POST',
      body: JSON.stringify({ action }),
    }),
  getMyLogoutStatus: (email?: string) => request<LogoutRequest | { status: 'none' }>(`/logout-requests/my-status${email ? `?email=${encodeURIComponent(email)}` : ''}`),
  managerLogout: (delegate_email: string) =>
    request<{ ok: boolean; message: string }>('/auth/manager-logout', {
      method: 'POST',
      body: JSON.stringify({ delegate_email }),
    }),

  // Expulsion and Member Status
  checkDeviceStatus: () => request<{ expelled: boolean; reason?: string; device_id?: string; user_email?: string }>('/devices/my-status'),
  expelUser: (email: string) =>
    request<{ ok: boolean; message: string }>(`/users/${encodeURIComponent(email)}/expel`, {
      method: 'POST',
    }),
  expelDevice: (id: string) =>
    request<{ ok: boolean; message: string }>(`/devices/${encodeURIComponent(id)}/expel`, {
      method: 'POST',
    }),
};

