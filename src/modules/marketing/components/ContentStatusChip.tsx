import React from 'react';
import { Chip } from '@mui/material';
import type { ContentStatus } from '../types';
import { statusColor, statusLabel } from '../lib/status';

export const ContentStatusChip: React.FC<{ status: ContentStatus }> = ({ status }) => (
  <Chip size="small" label={statusLabel(status)} color={statusColor(status)} />
);
