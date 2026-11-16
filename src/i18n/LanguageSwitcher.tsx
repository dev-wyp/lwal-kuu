import React from 'react';
import { FormControl, MenuItem, Select, SelectChangeEvent, SelectProps } from '@mui/material';
import { AppLanguage, useI18n } from './I18nContext';

export const LanguageSwitcher: React.FC<{ size?: SelectProps['size']; compact?: boolean }> = ({ size = 'small', compact = false }) => {
  const { language, setLanguage, t } = useI18n();
  const handleChange = (event: SelectChangeEvent<AppLanguage>) => setLanguage(event.target.value as AppLanguage);
  return <FormControl size={size} sx={{ minWidth: compact ? 112 : 145 }}>
    <Select
      value={language}
      onChange={handleChange}
      inputProps={{ 'aria-label': 'Language' }}
      sx={{ bgcolor: 'background.paper', fontSize: 13, borderRadius: 2 }}
    >
      <MenuItem value="en">{t("English")}</MenuItem>
      <MenuItem value="my">မြန်မာ</MenuItem>
    </Select>
  </FormControl>;
};
