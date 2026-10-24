import React, { useState } from 'react';
import {
  Plus,
  ArrowDownLeft,
  ArrowUpRight,
  Search,
  Trash2,
  Printer,
  MessageCircle,
  Image as ImageIcon,
  Eye,
  X,
  User as UserIcon,
  Phone,
  FileText,
} from 'lucide-react';
import { Transaction, Account } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';
import { usePermissions } from '../hooks/usePermissions';

interface TransactionsViewProps {
  transactions: Transaction[];
  accounts: Account[];
  onRefresh: () => void;
  onOpenTxModal: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const TransactionsView: React.FC<TransactionsViewProps> = ({
  transactions,
  accounts,
  onRefresh,
  onOpenTxModal,
  onShowToast,
}) => {
  const [typeFilter, setTypeFilter] = useState<string>('all');
  const [accountFilter, setAccountFilter] = useState<string>('all');
  const [search, setSearch] = useState<string>('');
  const [deleteTxId, setDeleteTxId] = useState<number | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [selectedTx, setSelectedTx] = useState<(Transaction & { account_phone?: string; account_whatsapp?: string; account_kind?: string }) | null>(null);
  const [showReceiptPreview, setShowReceiptPreview] = useState(false);

  const { canDeleteTx } = usePermissions();

  const filtered = transactions.filter((tx) => {
    const matchesType = typeFilter === 'all' || tx.type === typeFilter;
    const matchesAccount = accountFilter === 'all' || String(tx.account_id) === accountFilter;
    const matchesSearch =
      (tx.account_name && tx.account_name.toLowerCase().includes(search.toLowerCase())) ||
      (tx.description && tx.description.toLowerCase().includes(search.toLowerCase())) ||
      (tx.reference && tx.reference.toLowerCase().includes(search.toLowerCase()));
    return matchesType && matchesAccount && matchesSearch;
  });

  const handleConfirmDelete = async () => {
    if (!deleteTxId || !canDeleteTx) return;
    setIsDeleting(true);
    try {
      await api.deleteTransaction(deleteTxId);
      onShowToast('تم حذف العملية المالية بنجاح', 'success');
      setDeleteTxId(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف العملية', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  const formatMoney = (val: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(val || 0))} ${cur}`;
  };

  const getTypeBadge = (tx: Transaction) => {
    switch (tx.type) {
      case 'debit':
        return { label: 'عليه', class: 'bg-rose-50 text-rose-700 border-rose-200' };
      case 'credit':
      case 'inflow':
        return { label: 'له', class: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'revenue':
        return { label: 'مدفوع نقداً', class: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'outflow':
      case 'expense':
        return { label: 'سند صرف / مصروف', class: 'bg-amber-50 text-amber-700 border-amber-200' };
      default:
        return { label: tx.type, class: 'bg-slate-100 text-slate-700 border-slate-200' };
    }
  };

  const parseNoteValue = (notes: string | undefined, key: string): number | null => {
    if (!notes) return null;
    const regex = new RegExp(`${key}:\\s*([0-9.]+)`);
    const m = notes.match(regex);
    return m ? parseFloat(m[1]) : null;
  };

  const getTxFinancialSummary = (tx: Transaction) => {
    const isCash = tx.type === 'revenue';
    const itemsSum = (tx.items || []).reduce((s, it) => s + Number(it.total || it.quantity * it.unit_price || 0), 0);
    const noteTotal = parseNoteValue(tx.notes, 'إجمالي الفاتورة');
    const discount = parseNoteValue(tx.notes, 'الخصم') ?? 0;
    const invoiceTotal = noteTotal ?? (itemsSum > 0 ? Math.max(0, itemsSum - discount) : Number(tx.amount || 0));
    const paidAmount = isCash
      ? invoiceTotal
      : parseNoteValue(tx.notes, 'المبلغ المدفوع') ?? (tx.type === 'credit' || tx.type === 'inflow' ? Number(tx.amount || 0) : 0);
    const remainingAmount = isCash
      ? 0
      : parseNoteValue(tx.notes, 'المتبقي') ?? (tx.type === 'debit' ? Number(tx.amount || 0) : 0);

    return { isCash, invoiceTotal, discount, paidAmount, remainingAmount };
  };

  const handleShareWhatsApp = (tx: Transaction & { account_phone?: string; account_whatsapp?: string }) => {
    const acc = accounts.find((a) => a.id === tx.account_id);
    const phone = (tx.account_whatsapp || tx.account_phone || acc?.whatsapp || acc?.phone || '').replace(/[^0-9]/g, '');
    const summary = getTxFinancialSummary(tx);
    const badge = getTypeBadge(tx);
    const itemsText =
      tx.items && tx.items.length > 0
        ? '\nالأصناف:\n' +
          tx.items
            .map((it) => `• ${it.name} × ${it.quantity} = ${formatMoney(it.total, tx.currency)}`)
            .join('\n')
        : '';

    const msg = `🧾 *تفاصيل الفاتورة / السند #${tx.reference || tx.id}*
━━━━━━━━━━━━━━━━━━
العميل: ${tx.account_name || acc?.name || 'عميل نقدي عام'}
الحالة: ${badge.label}
التاريخ: ${new Date(tx.date).toLocaleString('ar-YE')}${itemsText}
━━━━━━━━━━━━━━━━━━
إجمالي الفاتورة: ${formatMoney(summary.invoiceTotal, tx.currency)}
الخصم: ${formatMoney(summary.discount, tx.currency)}
المبلغ المدفوع: ${formatMoney(summary.paidAmount, tx.currency)}
المتبقي: ${summary.isCash ? '0.00 ر.ي' : formatMoney(summary.remainingAmount, tx.currency)}`;

    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(msg)}`
      : `https://wa.me/?text=${encodeURIComponent(msg)}`;
    window.open(url, '_blank');
  };

  return (
    <div className="space-y-4">
      {/* Controls bar */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex flex-col md:flex-row md:items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          {/* Type filter */}
          <select
            id="select-tx-type-filter"
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
            className="py-1.5 px-3 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold text-slate-700 focus:bg-white focus:outline-hidden"
          >
            <option value="all">جميع أنواع العمليات</option>
            <option value="debit">عليه (مدين) 🔴</option>
            <option value="credit">له (دائن) 🟢</option>
            <option value="inflow">سند قبض 💵</option>
            <option value="outflow">سند صرف 💸</option>
            <option value="revenue">إيراد 📈</option>
            <option value="expense">مصروف 📉</option>
          </select>

          {/* Account filter */}
          <select
            id="select-tx-account-filter"
            value={accountFilter}
            onChange={(e) => setAccountFilter(e.target.value)}
            className="py-1.5 px-3 bg-slate-50 border border-slate-200 rounded-xl text-xs font-medium text-slate-700 focus:bg-white focus:outline-hidden max-w-[180px]"
          >
            <option value="all">كافة الحسابات</option>
            {accounts.map((acc) => (
              <option key={acc.id} value={acc.id}>
                {acc.name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex items-center gap-2">
          <div className="relative flex-1 md:w-56">
            <Search className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="بحث بالبيان أو المرجع..."
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>

          <button
            id="btn-add-tx-view"
            onClick={onOpenTxModal}
            className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
          >
            <Plus className="w-4 h-4" />
            <span>عملية جديدة</span>
          </button>
        </div>
      </div>

      {/* Transactions list */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">النوع والبيان</th>
                <th className="py-3.5 px-4">الحساب</th>
                <th className="py-3.5 px-4">المبلغ</th>
                <th className="py-3.5 px-4">التاريخ والمرجع</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-12 text-center text-slate-400">
                    لا توجد عمليات مسجلة مطابقة للفلاتر
                  </td>
                </tr>
              ) : (
                filtered.map((tx: any) => {
                  const badge = getTypeBadge(tx);
                  const acc = accounts.find((a) => a.id === tx.account_id);
                  const partyName = tx.account_name || acc?.name || 'عميل نقدي عام';
                  const partyPhone = tx.account_phone || tx.account_whatsapp || acc?.phone || acc?.whatsapp || '';
                  const partyKind =
                    (tx.account_kind || acc?.kind) === 'supplier'
                      ? 'حساب مورد'
                      : tx.account_id
                      ? 'حساب عميل'
                      : 'عميل نقدي عام';

                  return (
                    <tr
                      key={tx.id}
                      onClick={() => {
                        setSelectedTx(tx);
                        setShowReceiptPreview(false);
                      }}
                      className="hover:bg-slate-50/70 transition-colors cursor-pointer"
                    >
                      {/* Type & Description */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-3">
                          <div className="w-8 h-8 rounded-xl bg-slate-100 flex items-center justify-center shrink-0">
                            {tx.type === 'debit' ? (
                              <ArrowDownLeft className="w-4 h-4 text-rose-600" />
                            ) : (
                              <ArrowUpRight className="w-4 h-4 text-emerald-600" />
                            )}
                          </div>
                          <div>
                            <div className="flex items-center gap-1.5">
                              <span className={`text-[10px] px-2 py-0.5 rounded-full font-bold border ${badge.class}`}>
                                {badge.label}
                              </span>
                            </div>
                            <p className="text-xs font-semibold text-slate-800 mt-1">
                              {tx.description || 'عملية مالية'}
                            </p>
                          </div>
                        </div>
                      </td>

                      {/* Account */}
                      <td className="py-3.5 px-4">
                        <div className="font-bold text-slate-800">{partyName}</div>
                        <div className="text-[10px] text-slate-400 flex items-center gap-1.5 mt-0.5">
                          <span>{partyKind}</span>
                          {partyPhone && <span className="font-mono">• {partyPhone}</span>}
                        </div>
                      </td>

                      {/* Amount */}
                      <td className="py-3.5 px-4 font-mono">
                        <span className="text-xs font-black text-slate-900">
                          {formatMoney(tx.amount, tx.currency)}
                        </span>
                      </td>

                      {/* Date & Ref */}
                      <td className="py-3.5 px-4 text-slate-500">
                        <div className="text-[11px] font-mono">
                          {new Date(tx.date).toLocaleDateString('ar-YE')}
                        </div>
                        {tx.reference && (
                          <div className="text-[10px] text-slate-400 font-mono">
                            مرجع: #{tx.reference}
                          </div>
                        )}
                      </td>

                      {/* Action */}
                      <td className="py-3.5 px-4 text-left" onClick={(e) => e.stopPropagation()}>
                        <div className="flex items-center justify-end gap-1">
                          <button
                            onClick={() => {
                              setSelectedTx(tx);
                              setShowReceiptPreview(false);
                            }}
                            className="p-1.5 rounded-lg text-slate-500 hover:text-sky-600 hover:bg-sky-50 transition-colors"
                            title="عرض تفاصيل الفاتورة"
                          >
                            <Eye className="w-3.5 h-3.5" />
                          </button>
                          {canDeleteTx && (
                            <button
                              id={`btn-delete-tx-${tx.id}`}
                              onClick={() => setDeleteTxId(tx.id)}
                              className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                              title="حذف العملية"
                            >
                              <Trash2 className="w-3.5 h-3.5" />
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Upgraded Sales Details Dialog */}
      {selectedTx && (() => {
        const acc = accounts.find((a) => a.id === selectedTx.account_id);
        const partyName = selectedTx.account_name || acc?.name || 'عميل نقدي عام';
        const partyPhone = selectedTx.account_phone || selectedTx.account_whatsapp || acc?.phone || acc?.whatsapp || 'غير مسجل';
        const partyKind =
          (selectedTx.account_kind || acc?.kind) === 'supplier'
            ? 'حساب مورد'
            : selectedTx.account_id
            ? 'حساب عميل مسجل'
            : 'عميل نقدي عام';
        const badge = getTypeBadge(selectedTx);
        const summary = getTxFinancialSummary(selectedTx);
        const items = selectedTx.items || [];

        return (
          <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
            <div className="bg-white rounded-3xl p-6 max-w-lg w-full border border-slate-200 shadow-2xl space-y-4 text-right max-h-[90vh] overflow-y-auto">
              {/* Dialog Header */}
              <div className="flex items-center justify-between pb-3 border-b border-slate-200">
                <div className="flex items-center gap-2.5">
                  <div className="w-10 h-10 rounded-2xl bg-sky-50 text-sky-600 flex items-center justify-center">
                    <FileText className="w-5 h-5" />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <h3 className="font-extrabold text-base text-slate-900">
                        تفاصيل الفاتورة / السند #{selectedTx.reference || selectedTx.id}
                      </h3>
                      <span className={`text-[11px] px-2.5 py-0.5 rounded-full font-extrabold border ${badge.class}`}>
                        {badge.label}
                      </span>
                    </div>
                    <p className="text-xs text-slate-400 font-mono mt-0.5">
                      {new Date(selectedTx.date).toLocaleString('ar-YE')}
                    </p>
                  </div>
                </div>
                <button
                  onClick={() => setSelectedTx(null)}
                  className="p-1.5 rounded-xl text-slate-400 hover:text-slate-700 hover:bg-slate-100"
                >
                  <X className="w-5 h-5" />
                </button>
              </div>

              {/* 1. Party Info (بيانات الطرف) */}
              <div className="bg-slate-50 rounded-2xl p-3.5 border border-slate-200/80 space-y-2 text-xs">
                <div className="font-extrabold text-slate-700 flex items-center gap-1.5 pb-1 border-b border-slate-200/60">
                  <UserIcon className="w-3.5 h-3.5 text-sky-600" />
                  <span>بيانات الطرف (العميل / الحساب)</span>
                </div>
                <div className="grid grid-cols-3 gap-2 pt-1">
                  <div>
                    <span className="text-slate-400 block text-[11px]">اسم العميل:</span>
                    <span className="font-extrabold text-slate-900">{partyName}</span>
                  </div>
                  <div>
                    <span className="text-slate-400 block text-[11px]">رقم الهاتف:</span>
                    <span className="font-mono font-bold text-slate-800 flex items-center gap-1">
                      <Phone className="w-3 h-3 text-slate-400" />
                      {partyPhone}
                    </span>
                  </div>
                  <div>
                    <span className="text-slate-400 block text-[11px]">نوع الحساب:</span>
                    <span className="font-bold text-sky-700">{partyKind}</span>
                  </div>
                </div>
              </div>

              {/* 2. Detailed Financial Summary (الملخص المالي المفصل) */}
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
                <div className="bg-slate-50 p-2.5 rounded-xl border border-slate-200/80">
                  <span className="text-slate-400 block text-[10px]">إجمالي الفاتورة</span>
                  <span className="font-mono font-extrabold text-slate-900 text-sm">
                    {formatMoney(summary.invoiceTotal, selectedTx.currency)}
                  </span>
                </div>
                <div className="bg-slate-50 p-2.5 rounded-xl border border-slate-200/80">
                  <span className="text-slate-400 block text-[10px]">الخصم</span>
                  <span className="font-mono font-extrabold text-rose-600 text-sm">
                    {formatMoney(summary.discount, selectedTx.currency)}
                  </span>
                </div>
                <div className="bg-emerald-50/70 p-2.5 rounded-xl border border-emerald-200/80">
                  <span className="text-emerald-700 block text-[10px]">المبلغ المدفوع</span>
                  <span className="font-mono font-extrabold text-emerald-700 text-sm">
                    {formatMoney(summary.paidAmount, selectedTx.currency)}
                  </span>
                </div>
                <div className="bg-rose-50/70 p-2.5 rounded-xl border border-rose-200/80">
                  <span className="text-rose-700 block text-[10px]">المتبقي كمديونية</span>
                  <span className="font-mono font-extrabold text-rose-700 text-sm">
                    {summary.isCash ? '0.00 ر.ي' : formatMoney(summary.remainingAmount, selectedTx.currency)}
                  </span>
                </div>
              </div>

              {/* 3. Items Table (جدول الأصناف) */}
              <div className="border border-slate-200 rounded-2xl overflow-hidden text-xs">
                <div className="bg-slate-100 px-3.5 py-2 font-extrabold text-slate-700">
                  جدول الأصناف ({items.length})
                </div>
                {items.length === 0 ? (
                  <div className="p-4 text-center text-slate-500">
                    {selectedTx.description || 'عملية مالية بدون أصناف مفصلة'}
                  </div>
                ) : (
                  <table className="w-full text-right text-xs">
                    <thead className="bg-slate-50 border-b border-slate-200 text-slate-500 font-bold">
                      <tr>
                        <th className="py-2 px-3">اسم الصنف</th>
                        <th className="py-2 px-3 text-center">الكمية</th>
                        <th className="py-2 px-3">السعر</th>
                        <th className="py-2 px-3">الإجمالي</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {items.map((it, idx) => (
                        <tr key={idx}>
                          <td className="py-2 px-3 font-bold text-slate-800">{it.name}</td>
                          <td className="py-2 px-3 text-center font-mono">{it.quantity}</td>
                          <td className="py-2 px-3 font-mono">{formatMoney(it.unit_price, selectedTx.currency)}</td>
                          <td className="py-2 px-3 font-mono font-bold text-slate-900">
                            {formatMoney(it.total || it.quantity * it.unit_price, selectedTx.currency)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>

              {/* Optional Receipt Image Card Preview */}
              {showReceiptPreview && (
                <div className="p-4 rounded-2xl bg-slate-900 text-white space-y-2 text-xs font-mono border border-slate-700">
                  <div className="text-center font-bold text-sm border-b border-dashed border-slate-700 pb-2">
                    صورة إيصال #{selectedTx.reference || selectedTx.id} — ({badge.label})
                  </div>
                  <div className="flex justify-between">
                    <span>العميل: {partyName}</span>
                    <span>الهاتف: {partyPhone}</span>
                  </div>
                  <div className="flex justify-between border-t border-dashed border-slate-700 pt-2">
                    <span>المدفوع: {formatMoney(summary.paidAmount, selectedTx.currency)}</span>
                    <span>
                      المتبقي: {summary.isCash ? '0.00 ر.ي' : formatMoney(summary.remainingAmount, selectedTx.currency)}
                    </span>
                  </div>
                </div>
              )}

              {/* 4. Quick Action Buttons (أزرار إجرائية سريعة) */}
              <div className="grid grid-cols-3 gap-2 pt-2">
                <button
                  onClick={() => window.print()}
                  className="py-2.5 px-3 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
                >
                  <Printer className="w-4 h-4" />
                  <span>طباعة الفاتورة</span>
                </button>
                <button
                  onClick={() => handleShareWhatsApp(selectedTx)}
                  className="py-2.5 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
                >
                  <MessageCircle className="w-4 h-4" />
                  <span>مشاركة واتساب</span>
                </button>
                <button
                  onClick={() => setShowReceiptPreview((v) => !v)}
                  className="py-2.5 px-3 rounded-xl border border-slate-300 bg-slate-50 hover:bg-slate-100 text-slate-800 text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
                >
                  <ImageIcon className="w-4 h-4" />
                  <span>عرض الإيصال كصورة</span>
                </button>
              </div>
            </div>
          </div>
        );
      })()}

      {/* Confirm Delete Modal */}
      <ConfirmModal
        isOpen={deleteTxId !== null}
        title="تأكيد حذف العملية المالية"
        message="هل أنت متأكد من رغبتك في حذف هذه الحركة المالية؟ سيتم عكس تأثيرها على رصيد الحساب تلقائياً."
        confirmLabel="حذف العملية"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteTxId(null)}
      />
    </div>
  );
};
