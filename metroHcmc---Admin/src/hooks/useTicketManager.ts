import { useState, useEffect, useCallback } from 'react';
import { Form, message } from 'antd';
import axiosClient from '../api/axiosClient';

export const useTicketManager = () => {
  const [loading, setLoading] = useState(false);
  const [fareRules, setFareRules] = useState<any[]>([]);
  const [ticketProducts, setTicketProducts] = useState<any[]>([]);
  
  // Form 1: Cấu hình giá vé lượt
  const [fareForm] = Form.useForm();

  // Form 2: Sửa gói vé (MỚI)
  const [productForm] = Form.useForm();
  const [isProductModalOpen, setIsProductModalOpen] = useState(false);
  const [editingProduct, setEditingProduct] = useState<any>(null);

  // 1. Hàm lấy dữ liệu
  const fetchData = useCallback(async () => {
    try {
      setLoading(true);
      const [resRules, resProducts]: any = await Promise.all([
        axiosClient.get('/admin/fare-rules'),
        axiosClient.get('/admin/ticket-products')
      ]);

      if (resRules.ok) {
        setFareRules(resRules.data);
        // Điền dữ liệu vào form giá vé lượt
        const activeRule = resRules.data.find((r: any) => r.state) || resRules.data[0];
        if (activeRule) {
          fareForm.setFieldsValue({
            ...activeRule,
            base_price: Number(activeRule.base_price),
            step_price: Number(activeRule.step_price)
          });
        }
      }

      if (resProducts.ok) {
        // 🔥 CHỈ THÊM ĐOẠN LỌC NÀY:
        // Lọc để chỉ lấy đúng 2 loại vé gói có trong Database Enum
        const rawData = resProducts.data || [];
        const filteredData = Array.isArray(rawData) 
          ? rawData.filter((item: any) => item.type === 'day_pass' || item.type === 'multi_day_pass' || item.type === 'monthly_pass')
          : [];
          
        setTicketProducts(filteredData);
      }

    } catch (error) {
      message.error('Lỗi tải dữ liệu vé');
    } finally {
      setLoading(false);
    }
  }, [fareForm]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // 2. Lưu Fare Rule
  const handleSaveFareRule = async () => {
    try {
      const values = await fareForm.validateFields();
      setLoading(true);
      const res: any = await axiosClient.post('/admin/fare-rules', values);
      if (res.ok) {
        message.success('Cập nhật giá vé lượt thành công!');
        fetchData();
      } else {
        message.error('Lỗi: ' + res.message);
      }
    } catch (error) {
      console.error(error);
    } finally {
      setLoading(false);
    }
  };

  const openProductModal = (record: any = null) => {
    if (record) {
      setEditingProduct(record);
      productForm.setFieldsValue({
        ...record,
        price: record.price ? Number(record.price) : 0,
        // Chuyển từ Giờ sang Ngày khi hiển thị
        duration_days: record.duration_hours ? (record.duration_hours / 24) : 0,
        id_check: true,
      });
    } else {
      setEditingProduct(null);
      productForm.resetFields();
      productForm.setFieldsValue({
        state: true,
        type: 'daily_pass', // Giá trị mặc định
        duration_days: 1,
        auto_activate_after_days: 30,
        id_check: false,
      });
    }
    setIsProductModalOpen(true);
  };

  const handleSaveProduct = async () => {
    try {
      const values = await productForm.validateFields();
      setLoading(true);

      const payload = {
        ...values,
        // 🔥 Đảm bảo nhân 24 để lưu đúng số giờ vào Database
        duration_hours: values.duration_days * 24,
      };

      // Gọi đến API (Hãy chắc chắn đường dẫn này khớp với Backend của anh)
      const res: any = await axiosClient.post('/tickets/admin/products', payload);

      // SQL của anh trả về { success, message }
      // Controller trả về json(data)
      if (res && (res.success || res.ok)) {
        message.success(editingProduct ? 'Cập nhật thành công!' : 'Thêm vé gói mới thành công!');
        closeProductModal();
        fetchData(); // Tải lại danh sách để thấy vé mới
      } else {
        // Nếu Server trả về success: false
        message.error(res?.message || 'Lưu thất bại, vui lòng kiểm tra lại');
      }
    } catch (error: any) {
      // 🔥 ĐOẠN QUAN TRỌNG: Hiển thị lỗi nếu API bị lỗi (400, 404, 500...)
      console.error("Lỗi SaveProduct:", error);
      const errorMsg = error.response?.data?.message || error.message || 'Lỗi kết nối máy chủ';
      message.error('Lỗi hệ thống: ' + errorMsg);
    } finally {
      setLoading(false);
    }
  };
  // Đóng Modal
  const closeProductModal = () => {
    setIsProductModalOpen(false);
    setEditingProduct(null);
    productForm.resetFields();
  };

  
  return {
    loading,
    fareRules,
    ticketProducts,
    fareForm,
    handleSaveFareRule,
    refresh: fetchData,
    // Return thêm các biến mới
    productForm,
    isProductModalOpen,
    openProductModal,
    closeProductModal,
    handleSaveProduct
  };
};