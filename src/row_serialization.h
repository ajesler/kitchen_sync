#include <openssl/evp.h>

#define DIGEST_NAME "md5"

template <typename DatabaseRow, typename OutputStream>
struct RowPacker {
	RowPacker(Packer<OutputStream> &packer): packer(packer) {}

	~RowPacker() {
		// we use an empty array to indicate the end of the rowset
		packer.pack_array_length(0);
	}

	void operator()(const DatabaseRow &row) {
		packer.pack_array_length(row.n_columns());

		for (size_t i = 0; i < row.n_columns(); i++) {
			if (row.null_at(i)) {
				packer.pack_nil();
			} else {
				packer << row.string_at(i);
			}
		}
	}

	Packer<OutputStream> &packer;
};

struct Hash {
	unsigned int md_len;
	unsigned char md_value[EVP_MAX_MD_SIZE];
};

template <typename OutputStream>
inline void operator << (Packer<OutputStream> &packer, const Hash &hash) {
	packer.pack_raw((const uint8_t *)hash.md_value, hash.md_len);
}

inline bool operator == (const Hash &hash, const string &str) {
	return (hash.md_len == str.length() && string(hash.md_value, hash.md_value + hash.md_len) == str);
}

struct InitOpenSSL {
	InitOpenSSL() {
		OpenSSL_add_all_digests();
	}
};

static InitOpenSSL init_open_ssl;

template <typename DatabaseRow>
struct RowHasher {
	RowHasher(): row_count(0), row_packer(*this) {
		const EVP_MD *md = EVP_get_digestbyname(DIGEST_NAME);
		if (!md) throw runtime_error("Unknown message digest " DIGEST_NAME);
		mdctx = EVP_MD_CTX_create();
		EVP_DigestInit_ex(mdctx, md, NULL);
	}

	~RowHasher() {
		EVP_MD_CTX_destroy(mdctx);
	}

	const Hash &finish() {
		EVP_DigestFinal_ex(mdctx, hash.md_value, &hash.md_len);
		return hash;
	}

	void operator()(const DatabaseRow &row) {
		row_count++;
		
		// pack the row to get a byte stream, and hash it as it is written
		row_packer.pack_array_length(row.n_columns());

		for (size_t i = 0; i < row.n_columns(); i++) {
			if (row.null_at(i)) {
				row_packer.pack_nil();
			} else {
				row_packer << row.string_at(i);
			}
		}
	}

	inline void write(const uint8_t *buf, size_t bytes) {
		EVP_DigestUpdate(mdctx, buf, bytes);
	}

	EVP_MD_CTX *mdctx;
	size_t row_count;
	Packer<RowHasher> row_packer;
	Hash hash;
};

template <typename DatabaseRow>
struct RowHasherAndLastKey: RowHasher<DatabaseRow> {
	RowHasherAndLastKey(const vector<size_t> &primary_key_columns): primary_key_columns(primary_key_columns) {
	}

	inline void operator()(const DatabaseRow &row) {
		// hash the row
		RowHasher<DatabaseRow>::operator()(row);

		// and keep its primary key, in case this turns out to be the last row, in which case we'll need to send it to the other end
		last_key.resize(primary_key_columns.size());
		for (size_t i = 0; i < primary_key_columns.size(); i++) {
			last_key[i] = row.string_at(primary_key_columns[i]);
		}
	}

	const vector<size_t> &primary_key_columns;
	vector<string> last_key;
};

template <typename DatabaseRow, typename OutputStream>
struct RowHasherAndPacker: RowHasher<DatabaseRow> {
	RowHasherAndPacker(Packer<OutputStream> &packer): packer(packer) {
	}

	~RowHasherAndPacker() {
		// send [hash, number of rows found] to the other end.  ideally we'd use a named map
		// here to make it easier to understand and extend, but this is the very core of the
		// high-rate communications, so we need to keep it as minimal as possible and rely on the
		// protocol version for future extensibility.
		packer.pack_array_length(2);
		packer << RowHasher<DatabaseRow>::finish();
		packer << RowHasher<DatabaseRow>::row_count;
	}

	Packer<OutputStream> &packer;
};