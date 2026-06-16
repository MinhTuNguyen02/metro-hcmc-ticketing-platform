import axiosClient from './axiosClient';

const scanTicket = async (qr_code: string, station_code: string, direction: 'IN' | 'OUT') => {
  return await axiosClient.post('/scanner/scan', {
    qr_code,
    station_code,
    direction
  });
};

export const scannerApi = {
  scanTicket
};