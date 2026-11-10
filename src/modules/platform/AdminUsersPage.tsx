import React, { useState } from 'react';
import {
  Box,
  Typography,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Chip,
  CircularProgress,
  TextField,
  InputAdornment,
  Avatar,
  Card,
  CardContent,
  Grid,
} from '@mui/material';
import PeopleIcon from '@mui/icons-material/People';
import SearchIcon from '@mui/icons-material/Search';
import AdminPanelSettingsIcon from '@mui/icons-material/AdminPanelSettings';
import StorefrontIcon from '@mui/icons-material/Storefront';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';

export const AdminUsersPage: React.FC = () => {
  const [searchQuery, setSearchQuery] = useState('');

  // Fetch all profiles along with their organization memberships
  const { data: users = [], isLoading } = useQuery({
    queryKey: ['admin_all_users'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select(`
          id,
          full_name,
          email,
          phone_number,
          is_platform_admin,
          created_at,
          organization_members(
            role,
            is_active,
            organizations(id, name, slug)
          )
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data || [];
    },
  });

  const filteredUsers = users.filter((u: any) => {
    const q = searchQuery.toLowerCase();
    const nameMatch = u.full_name?.toLowerCase().includes(q);
    const emailMatch = u.email?.toLowerCase().includes(q);
    return nameMatch || emailMatch;
  });

  const totalUsers = users.length;
  const adminUsers = users.filter((u: any) => u.is_platform_admin).length;
  const regularUsers = totalUsers - adminUsers;

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <PeopleIcon sx={{ fontSize: 36, color: '#6366f1' }} />
        <div>
          <Typography variant="h4" sx={{ fontWeight: 800 }}>
            Global Platform Users
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Cross-tenant user directory, administrative permissions, and assigned wholesale shops.
          </Typography>
        </div>
      </Box>

      {/* User Metrics */}
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={4}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700 }}>
                TOTAL REGISTERED USERS
              </Typography>
              <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5 }}>
                {isLoading ? <CircularProgress size={20} /> : totalUsers}
              </Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={4}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700 }}>
                PLATFORM SUPER-ADMINS
              </Typography>
              <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5, color: '#dc2626' }}>
                {isLoading ? <CircularProgress size={20} /> : adminUsers}
              </Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={4}>
          <Card elevation={0} sx={{ border: '1px solid #e2e8f0', borderRadius: 2.5, bgcolor: '#ffffff' }}>
            <CardContent sx={{ py: 2, '&:last-child': { pb: 2 } }}>
              <Typography variant="caption" color="text.secondary" sx={{ fontWeight: 700 }}>
                SHOP TENANT MEMBERS
              </Typography>
              <Typography variant="h5" sx={{ fontWeight: 800, mt: 0.5, color: '#0284c7' }}>
                {isLoading ? <CircularProgress size={20} /> : regularUsers}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Paper elevation={0} sx={{ p: 2.5, borderRadius: 3, border: '1px solid #e2e8f0', bgcolor: '#ffffff' }}>
        <Box sx={{ mb: 2.5 }}>
          <TextField
            size="small"
            placeholder="Search users by name or email..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            sx={{ minWidth: 320 }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" color="action" />
                </InputAdornment>
              ),
            }}
          />
        </Box>

        <TableContainer sx={{ border: '1px solid #e2e8f0', borderRadius: 2 }}>
          <Table>
            <TableHead sx={{ bgcolor: '#f8fafc' }}>
              <TableRow>
                <TableCell sx={{ fontWeight: 700 }}>User</TableCell>
                <TableCell sx={{ fontWeight: 700 }}>Email Address</TableCell>
                <TableCell sx={{ fontWeight: 700 }}>Platform Role</TableCell>
                <TableCell sx={{ fontWeight: 700 }}>Associated Shops / Roles</TableCell>
                <TableCell sx={{ fontWeight: 700 }}>Registration Date</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={5} align="center" sx={{ py: 6 }}>
                    <CircularProgress size={32} />
                  </TableCell>
                </TableRow>
              ) : filteredUsers.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} align="center" sx={{ py: 6, color: 'text.secondary' }}>
                    No users found matching your search.
                  </TableCell>
                </TableRow>
              ) : (
                filteredUsers.map((u: any) => {
                  const memberships = u.organization_members || [];
                  return (
                    <TableRow key={u.id} hover>
                      <TableCell>
                        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
                          <Avatar sx={{ width: 32, height: 32, bgcolor: u.is_platform_admin ? '#dc2626' : '#0f172a', fontSize: 13, fontWeight: 700 }}>
                            {u.full_name ? u.full_name[0].toUpperCase() : 'U'}
                          </Avatar>
                          <Typography variant="body2" sx={{ fontWeight: 700 }}>
                            {u.full_name || 'Unnamed User'}
                          </Typography>
                        </Box>
                      </TableCell>
                      <TableCell sx={{ fontFamily: 'monospace', fontSize: 13 }}>
                        {u.email || '-'}
                      </TableCell>
                      <TableCell>
                        {u.is_platform_admin ? (
                          <Chip
                            icon={<AdminPanelSettingsIcon sx={{ fontSize: '14px !important', color: '#ffffff' }} />}
                            label="SUPER ADMIN"
                            size="small"
                            sx={{ bgcolor: '#dc2626', color: '#ffffff', fontWeight: 800, fontSize: 10 }}
                          />
                        ) : (
                          <Chip
                            label="TENANT USER"
                            size="small"
                            sx={{ bgcolor: '#e2e8f0', color: '#475569', fontWeight: 700, fontSize: 10 }}
                          />
                        )}
                      </TableCell>
                      <TableCell>
                        {memberships.length === 0 ? (
                          <Typography variant="caption" color="text.secondary">
                            None (Pending Onboarding)
                          </Typography>
                        ) : (
                          <Box sx={{ display: 'flex', gap: 0.8, flexWrap: 'wrap' }}>
                            {memberships.map((m: any, idx: number) => (
                              <Chip
                                key={idx}
                                icon={<StorefrontIcon sx={{ fontSize: '12px !important' }} />}
                                label={`${m.organizations?.name || 'Shop'} (${m.role})`}
                                size="small"
                                variant="outlined"
                                sx={{ fontSize: 11, fontWeight: 600 }}
                              />
                            ))}
                          </Box>
                        )}
                      </TableCell>
                      <TableCell>{new Date(u.created_at).toLocaleDateString()}</TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>
    </Box>
  );
};
