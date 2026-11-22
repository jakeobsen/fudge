import Foundation

// OAuth sign-in through a fudge-oauth relay (SPEC-056, decision D-63). The relay holds the OAuth apps' secrets and
// lives in its own repository, jakeobsen/fudge-oauth. Fudge holds none: it sends `@raycast/utils`' built-in providers
// to the relay instead of Raycast's servers, and keeps the tokens in the Keychain.

/// One of the providers `@raycast/utils`' `OAuthService` has built in, with its default URLs (2.3.3), Raycast's own
/// proxy for one, as a store extension sets it, or another of Raycast's sign-in addresses a store extension uses
/// (FUD-166): a proxy per service, or its author's app on Raycast's shared proxy.
public struct OAuthProvider: Sendable, Equatable, Codable {
    /// The relay's path segment: `<server>/<id>/authorize`. Two entries share one when they're a provider's own URLs
    /// and Raycast's proxy for it (Atlassian's, Zoom's), or two extensions' addresses for one service (GitHub's,
    /// Notion's); an entry is known by its authorize URL.
    public let id: String
    public let name: String
    public let authorizeURL: String
    public let tokenURL: String
    /// Where `OAuthService` sends a refresh. For Google, Jira, Zoom, Todoist, `github-copilot`,
    /// `raycast-pomodoro-notion` and `bangumi` that's the token URL, so a request there is a refresh when its
    /// `grant_type` is `refresh_token`.
    public let refreshURL: String

    public init(id: String, name: String, authorizeURL: String, tokenURL: String, refreshURL: String) {
        self.id = id
        self.name = name
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.refreshURL = refreshURL
    }
}

/// The one table of providers Fudge signs in to. Only these exact URLs are ever sent to the relay.
public enum OAuthProviders {
    public static let all: [OAuthProvider] = [
        raycastProxy("github", "GitHub"),
        // The store's `github-copilot` extension signs in with its author's GitHub app through Raycast's shared proxy, and
        // refreshes at its token URL. The relay's GitHub app takes the author's place.
        OAuthProvider(
            id: "github", name: "GitHub",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/ZJFTemDOnon9VgfOxbFostk2HJqDaHtXFizUhliOj5WNPEcL3n9Mjzf_NWXwTDo5UHmMpzAaX0hOk5GZggt_Gkq7J3VlakVu7C67POdoLtId--l3BOI9j-rxsyrYqdo4iFocQmEFYpNGY97ulVc",
            tokenURL:
                "https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc",
            refreshURL:
                "https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc"
        ),
        raycastProxy("linear", "Linear"),
        raycastProxy("slack", "Slack"),
        raycastProxy("asana", "Asana"),
        OAuthProvider(
            id: "google", name: "Google", authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token", refreshURL: "https://oauth2.googleapis.com/token"),
        // One Atlassian app covers Jira and Confluence: `confluence-search` signs in at Atlassian's own URLs, and the
        // store's Jira extension through Raycast's Jira proxy.
        OAuthProvider(
            id: "atlassian", name: atlassianName, authorizeURL: "https://auth.atlassian.com/authorize",
            tokenURL: "https://auth.atlassian.com/oauth/token", refreshURL: "https://auth.atlassian.com/oauth/token"),
        raycastProxy("jira", atlassianName, relay: "atlassian"),
        OAuthProvider(
            id: "zoom", name: "Zoom", authorizeURL: "https://zoom.us/oauth/authorize",
            tokenURL: "https://zoom.us/oauth/token", refreshURL: "https://zoom.us/oauth/token"),
        // The store's Zoom extension signs in through Raycast's Zoom proxy.
        raycastProxy("zoom", "Zoom"),
        // The store's Notion extension signs in through Raycast's Notion proxy, and refreshes at its token URL.
        raycastProxy("notion", "Notion"),
        // The store's `raycast-pomodoro-notion` extension signs in with its author's Notion app through Raycast's shared
        // proxy, and refreshes at its token URL. The relay's Notion app takes the author's place.
        OAuthProvider(
            id: "notion", name: "Notion",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/c7Qokr0CiZIEHW7WoevaKukgEOtjEFGI1lYt3_kYC6k8CNeqRO8xF9BtpZUePirKQM2KwJH21RCJI1I2I4VeutakujJ2EZJQoypCI_Cg4OOaRCqT4a5MLxiYcBHGDXsp52ewVVrzzGM5KjfY951bomaB3ELg6qoLeQ",
            tokenURL:
                "https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-",
            refreshURL:
                "https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-"
        ),
        // The store's Todoist extension signs in through Raycast's Todoist proxy, and refreshes at its token URL.
        OAuthProvider(
            id: "todoist", name: "Todoist", authorizeURL: "https://todoist.oauth-proxy.raycast.com/authorize",
            tokenURL: "https://todoist.oauth-proxy.raycast.com/token",
            refreshURL: "https://todoist.oauth-proxy.raycast.com/token"),
        // The store's `trek` extension signs in to Basecamp with its author's app through Raycast's shared proxy. The
        // relay's Basecamp app takes the author's place.
        OAuthProvider(
            id: "basecamp", name: "Basecamp",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/Yu5bylqUnHj-jHAkK4iRGFKxrV_ObMQz4TEPVf4zHD3UxkB9A2WIdhPF18B4B76kimV7t1ks7MZQE2wqKh6Zc9MVsxKqVB2CLZvhZfnkTBzRu1YXFn9EXbPJz0602roPZLt6p_x-PWbvi5OG8JIaZFkyiqbnkVE",
            tokenURL:
                "https://oauth.raycast.com/v1/token/wMaXr3BdE5QWGZQ_RE_7GyB37_wTuBYOg_9C7CxiqtwHYOELsCyxDKiOshV4mPWXj9NZ_cZ9-dLIkELMnqbN08GDHCnmBp0i2Z950v2kWuOU88VMf3YxkiQAxj5HiAGYW9ceuj9hTDeIBYyBIXciFpDsR6WPhJAjJsHqvz2j8IQQe28efSJFi18",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/zUVueWjJBw5e_3E04mUmut6L1LiT8fa6FdubGOtITFX_Gx3nilkwNIUISui62gZbvu6yXqDWHy7UKdM9R5RXPUQu-9q-zEsgnK2NhTktNwp2wmGT60Rg-mXFUUd_jg4fwBzIXj5cOBculalOYYodpTWi8bJJBp60XCxA_0C4hctAhKftD8soF-A"
        ),
        // The store's `gumroad` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // Gumroad app takes the author's place.
        OAuthProvider(
            id: "gumroad", name: "Gumroad",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/6u4QNlwsUEvYJiwlmx-jGSBLpe0QloUowsc9PMy64xyP31e0kMWtiJCyTz4b_9EPuycLxrAIvZfFtVczX9fPJfU5Xt5h2ib3aZRDa85rRqQbFe1hqyVXIQdIPXo2mZdkSp9N7P2pFtAeykI3",
            tokenURL:
                "https://oauth.raycast.com/v1/token/cAfVd74pOuU0WIWMymDxtIHXg2c1Hai7gBXmE4DZGFk4tRZczsTQlJzrFzbwSYE3TmlIEse4FP4uUy9EYX35zYfsI0_2mfKmLudJ4wsC-8zUsEXhJwnIn11TJmNeH2bpiWxqQpU-K4Q",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/-8K39Rwy5HY5-DzNTOVLTMvKH6EQVd5E50z9mvLJ4bahXJu2susPq_DcGFFUYrhctLgTTXZLhmYRvlBnpIaGuxPDB7QTscbBrsz63tOA4RvPXoqJYh4JKtyUgQMAheFWBKh6gvNI08Q"
        ),
        // The store's `moneybird` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // Moneybird app takes the author's place.
        OAuthProvider(
            id: "moneybird", name: "Moneybird",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/2QijvWZlCgJtKVzE9EG_mGx2DulRYvJQZlKC0cN8CwjSTccDV-mwsxiRx03lbj63Hl53CKRb5vi37PJ8AJMvarHholI5CvrGbIX7AeIIyoqcX-bAF2bnwnKGWzK-7EWxqJxog9aX4KD1lS_CyVONoOBVhhCIsTUpzeuusGMuDfD-H90",
            tokenURL:
                "https://oauth.raycast.com/v1/token/HkdQIb7W7JlFwNFCj2yL6zDPvJHb-vnTCrL_iPlT_K77Z-hQHyRJ-iiLSrkfjNta8Yys7_qRGKHBiAIVVt5GnqiV-VvvegeT9INJ24TrXTHk_P2MT0GOTd8fD9ogDuOgdPyMahi1mePSjhGKHTsBuPloYZFqNnDSzr4_ioxJBQ",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/66Tt7sCc6O70T4V3Rf_Dr4B941f08fkyizdDhimTODW0M7niNRllwvyk7FLX3XLaj0WNAWZBeOG1fZ8E1aTYWQR8ThljnyaUy3zS68Ocd5oxI6p4SUY7q2oIs_IauacmW75epq8Mn-mrdcpnmpuL19R7iPHgFy3FBS1ZeHRbSg"
        ),
        // The store's `freeagent` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // FreeAgent app takes the author's place.
        OAuthProvider(
            id: "freeagent", name: "FreeAgent",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/PLlKWDuFWQjTTgdJHUy-wK47_zN8lc2ATzyvHJSoNy5WazXXYTG_h8Yz1eOPwlUvB-YNQos46o_9lgTxwUdQN3L9P4LsjYwgitMYkEmcHtGHsUyZYyBXwng3lgE",
            tokenURL:
                "https://oauth.raycast.com/v1/token/csqaHeGaTfTpistIum6eBy7DDrJjcz7Z-FmW_HuU4Dsa3r-AhgMCGcEWYUCLR3k-5-PirrX1ilceu4WfRqUQlyCSEiYqzkZkIIKyx5n7khRbIe99FHiEBtENFXUZRz8",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/wg1eYlPV441y6BfHcmZi19x61W2tqw045Dup4C6M8VgERbxtFByj1J97OeYVaiPHbYWoLz3nNnZ3nzXoMnZbqP6EhVYkT8eJefM79ey5sQLcdRL9vGnlBsLMqaB_Ylg"
        ),
        // The store's `mollie-for-raycast` extension signs in with its author's app through Raycast's shared proxy.
        // The relay's Mollie app takes the author's place.
        OAuthProvider(
            id: "mollie", name: "Mollie",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/NxaZKqcp7vp8pAw3Mp8r8UOXy_z3pnka8zfft5NcBEoB09N36m-7Y6r_EBUphunBEkTTec8UnAC_hq1ENW73rgp77by3LF_mXqJ4ct1g9kqbLRe8Hx1ezlHoU2sxnqKZfzHWkdV7hGugdqZksA",
            tokenURL:
                "https://oauth.raycast.com/v1/token/5p7_7xQdzkXilZdhppv_or2B9wwd0Sm7Fx0khb74h_MHnro7AO5w4tr9-aj5vJe4C0NnlLsV1Onr24ndgmFR5J_yRpV6b_hD8BzYSg6lcH1Q7s-1DUfZ0JFlZjE2nF0j-vunQ34iLi8d8w",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/hiXK17eErlQSoxjH5w0qTI3fjCmQt-Qw7TWqV0PhNEi6xvSqLjnklSkwNy7D0g67FwQAfXV3udahWqjl2tFPa5b7zO_rFNtJQTvPto9gQMrQDdQFFC6VvdGZstEn8K2juivJh2SwmBzBfg"
        ),
        // The store's `plane` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // Plane app takes the author's place.
        OAuthProvider(
            id: "plane", name: "Plane",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/dAAojlwLRis2jBTlrt8vrrmmaMYGJO0ZuPZb8awD6ouUaNVltt_bEeZACr4zFPcHvV0U5IVaAabS3IWAn0R-JN1vvk1g5WqXSrYpyH9SQAXQ2-nquGy9KhyrfKd8JnnBFC0kMLzniS13BIrr0F9mbrSMZuhXITeAlgHSnlJcqHBw7MMYbLNfwbMbeHPofwDPbroIsU1l8VVPQpu3Xba8L0jy6rBAQeczGhi0ghcoEfeuogNd5r3CRyU9WgCGoB3e7VqNvWNk5e0",
            tokenURL:
                "https://oauth.raycast.com/v1/token/9KXLatvC9QrbuSafABDqcnA8IZW-JXwd4FF4CvZ-C6LFXfbl8FONXyjGuaO1n2XEFIW6bvDFFWDKH5IB_9gupDVVPiAHt5_mNmQJTQ_OmF7AYcKe6fF3I13O_hYIOETpCPknFn9ww9arA93J2knoGIWRSE-FFoVB2_lBGL8xP8FaRaj8_S6M-fsKUOg1YyyOFaK6dIIN5LF8i6P5J8y_L8Q6hWu4ZyyxmLCKHmEyPY9uoK-6ZZ27W0LMIrNzSHTS",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/dERRhlRqcHTtXPJLaZZqs7h8JYsRPZrQeWpVvNN_5F9qd_Z6Hb1q6xr_iVeLUmKBj9Ewk3xHAuADSKCpQ1fb0rJq07vziFLkate0VW2zkV0a-xfj23KBoVM2y50aA4geUo7XQT4PS0MKFBIt44ZaD0QRnr3gdZIf37xWollM66pK35YAmuIgo4uFDFJnj1-A1zJ8FvuYL16tHK5qO4nK6SBKE-AktYpraqpziJUINAwN6ByKe_JO1MdvtGGeMb-5"
        ),
        // The store's `homey` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // Homey client takes the author's place.
        OAuthProvider(
            id: "homey", name: "Homey",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/WTWZbnJLBrEo1FEYJ0E4Ix5Wpsxnpfkcb5d2EURGgmOtgPnpIE8QvYHgJX0LeG9yryHZ71LssD1tli8bdKKVlKuEIMx-W-Ql8H72V2kBFkRgv0HPkPPGPv6ULdVrop4rZsMi-kohkLrs7glA",
            tokenURL:
                "https://oauth.raycast.com/v1/token/7EXpLgXJ1PDijhpr-BiJe3CVd8JGSZsST-oAdflCaTWLJuEE0vRMulR8bHGX4SRrBJWgXgZKC4A0b2jF90p7QELwCoXdZQnHrigsXbfLOolG1PwDUbDNB971f6EllEs4ndcak66nGw8",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/ptpJtGSqQUGUt9zDDZGzv4iW-Vn7965_rjjtPM3sOeRSXhXL_GIF4ZrNDUR21AhW5zg-MUeZuMdoKG1co7oEkas3HYBat5-W4rLPUMScN0yOM5zlapM6xD-ryNobzZ55v22lc_5qXKo"
        ),
        // The store's `figma-files` extension signs in with its author's app through Raycast's shared proxy.
        // The relay's Figma app takes the author's place.
        OAuthProvider(
            id: "figma", name: "Figma",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/F7SnNEtLc3w2AFfhwdtXwpE-rW2l2OOtG3h0z76VKM6YJVtkU17gAmgJgqzIn6lO3X9SCv_iv3_3BS8a1Jq0gc14HUxILPg8wQNB8zBaX4-OjUj2ixG0",
            tokenURL:
                "https://oauth.raycast.com/v1/token/rsuQtsavqnjuxmA3vCYSGa3E-D8_ruhzY4OqJIOA7aB4_wGaFh2WE0mQc_uMZ7E5Nk8-pAeW3JXE3WlUfgqu_-zNiM4yWU7i_z2-u0pO8HJFh7_H6ohVBh8fcDpk64nT",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/qJfyXOqhjDouaj06_54vl2O3NoIfY36R_-OOExXZNAS073Bih0aeNaHLO9xEpW6lbooqWCpT6zO7zLvbTx1MtXF2dU5d4B_of5d05Yxh27JIAPHG0uBw7fINhej_ViQ-sbE"
        ),
        // The store's `42-api` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // 42 app takes the author's place.
        OAuthProvider(
            id: "intra42", name: "42",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/MnlQFVxIGQ4k6vhqj0q7FUyjXQs7FbP504oq2kWvU0DQ7ydArhDDZo_0RZLytPp3cBI4XAAi6JhEM4dq3POHTarPLiM-OJScM_6D1S3WCTynD_ArEsOIIihJC7KQvZL3X5vaDaKBygzemteTqVfTT3mxFpHXRwDMaMwKrSBimszqxqSJre9Cm_rkaA4ovOKh9A",
            tokenURL:
                "https://oauth.raycast.com/v1/token/CQ8Acmd1GJ7WXGwXJ0BdBOtMhyiGcdZMPpq7pnM74LNkLiB6gRMSJ33oMtJ0bGkKFlG3IitUPqnW89BL8_VQ6t6Vex1Znps-pAd0itvAr1q0VaawTwfopc43vp-soOvKY9A1U8dfeKGOh9iDyGWrN-_NsDEO-UcJTazwwIBaPo1hRX4kdlHWRueDTrXS",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/3M-j9Q4RZaZelFapmWrXeGPyaVV2zce7OIBsa7_8yMZ-Z-wH0UnsPVvGlNwo3n8IBZs-dEyVDLVusP6hjYD4seIut6Jv24LtdvogyEDNcuRpOmyb6DEX-hnvnT56MH47XJ-aNiCWAJC4SIn3WeMA7T-wdlbsuxWvHA1Aw7IyA5jNLwTyALavTOnrY69W"
        ),
        // The store's `ticktick-plus` extension signs in with its author's app through Raycast's shared proxy. The
        // relay's TickTick app takes the author's place.
        OAuthProvider(
            id: "ticktick", name: "TickTick",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/mgIpKnxTo3jdnE1IUETN_zw4tSRTSnH6DffToE_gh1deVyanGQ53X1ZN8QrZtl8XgYkARnurl9iQVFtuOvNYPMmaEtZoY05ZV7KmAF4GE2NNmlJScX8Hd3_RRm054E_hRus",
            tokenURL:
                "https://oauth.raycast.com/v1/token/SXhT3SrBQS_UHzaHXdkI28IHvtPy1y79lN5b7WoFnWn6gbvztRZkAL906CUce9e4DbOLgWxhVLCG_Bxi0Ur3d4H7bBprZDsofulVmBBdNJgrF1mH-b2iJRDck9uLWA",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/sZgB0AoTB26kqAhJ7pKwC-c0Csk7iMGAQ3OwBADMcZd0ntppCz-q3tTb4VRgutPDL-JiXn4JbkrkCggRXIlO5mQp7VJvLO7XuPxJ2oqLO7dJPEziEKzsKHEeMRgfGw"
        ),
        // The store's `zoho-mail` extension signs in with its author's Zoho app through Raycast's shared proxy. The
        // relay's Zoho app takes the author's place.
        OAuthProvider(
            id: "zoho", name: "Zoho",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/L56YnDJ7Pyv-SZlWPCgVlUHSVMI4Eo71Yzox2S9xDRtI83vegut87tcNRpoby4W-_L3m6rYKozB71tAb1THv3G00VX-9rvnQ5klOYengXzr7E8GE6pEIFP9rCqF2KCHqAV_yVzzjYYgt7ztx3FS1",
            tokenURL:
                "https://oauth.raycast.com/v1/token/IzJ2IgubKiVDyntspLduHwp2fbqLnidriix9jaZCAzZbj2wdsPWfJpv3TUtpQCRyopHNO1YPx0HgWOiQlaIaDiJu8zCrnvxFsp9beqRPVE1w5acImQsJ3BHoVq36OD3mAS6BV0FlkgzkPWjcqjMvzg",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/PkgYXNFbQinA8SK-3Wvcl8xdP7Hq-kaX6ur_sct3_qk_ATrFgb8uneFkkpkwlACWOjsnG_TIvW75N7SdQ9Afd-ZfeKxtqdHj2yYEfg5Y0oueBi8zBwGoRWc-sglHUgecZaF2PQfuzqKZ0JoXL2JP4w"
        ),
        // The store's `webflow-sites` extension signs in with its author's app through Raycast's shared proxy. The
        // relay's Webflow app takes the author's place.
        OAuthProvider(
            id: "webflow", name: "Webflow",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/SpqHimJblCsEsHMaOX6bSCGCatuNIU9D8vHt3qn0eGhM9Dhqs-K2TDWF2KFer-G-LizUGpxKDwkTBA-oGVs9yAJzI-GsWPkS3UTCbil0P5rY5VxHVic2kuBzEaQan7HBhfvFHLwOYnbd69mx0blWKqXxgWW7sZ3FqagkphxttM0n",
            tokenURL:
                "https://oauth.raycast.com/v1/token/q4QKZun0V_mQeHqwiKbrv-G8fdDGM1-an2xu3vMO5AqrmUHnzIC4pjEpHf_I2XWtpR3uMK42EtKQiqNljaEE3rtacJnOHrip0_2B4K7Ci3WClmnjzv9gwmyYtmaGl4qIeU10j2RTDWVRq_jeUwc5Ze2_RCwYWdikkqKsfiLkJWZVahPvI0-RaA",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/OUvaPcCuUx4pAsmO9NlL0SjzRIsj1iquQtVbDxZlJHw5AxRqpEykQrSAKVa13YZNyTulfh8hUtGnOsmNEdMCyvflcIegE6MhbCr5BYS9Zdznb95mcJiXhduhwmXr9OXV6srwF4DmOUEnVwMzH7Pv8i8KmFxRRjbmm9rku70X_yNeVIxu9bzKzg"
        ),
        // The store's `bangumi` extension signs in with its author's app through Raycast's shared proxy, and
        // refreshes at its token URL. The relay's Bangumi app takes the author's place.
        OAuthProvider(
            id: "bangumi", name: "Bangumi",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/nAxnz5SEQ7fO5SRxM_DjKrJ4k3C00kfJCNh1-fp_ZcDFXVcYIxtPBI5BbGux3-EOO8WfSheAkSZ7EJRtTfq1EQkaxB4ZKpkJ9byrPZZfYMx35C1Ii85HfKYDVo4",
            tokenURL:
                "https://oauth.raycast.com/v1/token/7CSgIYGNn4jFuD6fTG5ov64wsfsi3iegonKLu0FCzW4pWL1T1jgXa4Bxa4f5w-bZOModMtBbrKFPsx1bGT4LUL_pmFzC1O3PkRp4Al1FToLwL_OPG4wVCAnQBQv6d2A",
            refreshURL:
                "https://oauth.raycast.com/v1/token/7CSgIYGNn4jFuD6fTG5ov64wsfsi3iegonKLu0FCzW4pWL1T1jgXa4Bxa4f5w-bZOModMtBbrKFPsx1bGT4LUL_pmFzC1O3PkRp4Al1FToLwL_OPG4wVCAnQBQv6d2A"
        ),
        // The store's `wave` extension signs in with its author's app through Raycast's shared proxy. The relay's
        // Wave app takes the author's place.
        OAuthProvider(
            id: "wave", name: "Wave",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/FM5tM_5g15vFDnfj7nm3vtkcoByMUAI69cCl58SB27ud1QGVoveYNA_BgjcsXvWyDqBQVyZoLYaUlIlZvpFcPvXxK7MqOHeO5hN5y0qwEnShw9Hv9PofZM7xqADLOih2-W62ftFCaRDVJIur7F0ccG7xVu8t8wSt3VXL5i7o3IQIPQ7ODWqswTt6Fx5KxL5y5MuqAgxP2jr7Xwz-yWQWc_A7EaKPxbno2oTPaz9AArfAd-t-YaPbXvTL3bi69cu1CmVTJygRdhM",
            tokenURL:
                "https://oauth.raycast.com/v1/token/_wJ5kXg1rLhO75Pr62ge83y20RUwQ7SITWBOL86St6DKEY-FK1p9yWdFqDhcFE_SgHgaYril7-RoS3JfDNs5lVX8xQ2iEX2LAXmDQV8armzVls1lWJYKHVSw123e6h9d-C3JUkDzhYfBiWY6HaMrn2E03dhqiuiBN5SOLAfCqZKTgq1ULnvfJ7Nexi82FN54jsrn2gyHDspcz6d89jWStRIPvFSeVt3C3EEPmdnWbm7mKZNmxhuoFrOZ1B8N-KOObts8Bg",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/TQsitwYgPmfM2Tm6ZC5NMaBiOIztfOmzALSrh4UM0o4SdlSqRCvGuJ3i56HXpOkkuiwOc0TtKfxtfBKDy96nmDKMfewczvXkpNnH1afTexQYGUDTQOpUYBE8Cxo9XMRdqdJKC2OIUitHjCXZHEAQDLaGNo5AXMeWKO4Kkg6MLooZuy2Zuh16neM6-DCwJ8Qs1ZLPHdF6ps8vZRd-viNgscOto3NwUXa4iOVWLXsn8xrVD3tOcCcDvC3R-JOIzn-5ipsSZQ"
        ),
        // The store's WHOOP extension signs in through Raycast's WHOOP proxy.
        raycastProxy("whoop", "WHOOP"),
        // The store's Miro extension signs in through Raycast's Miro proxy.
        raycastProxy("miro", "Miro"),
        // The store's `tesla-energy` extension signs in to Tesla with its author's app through Raycast's shared
        // proxy. The relay's Tesla app takes the author's place.
        OAuthProvider(
            id: "tesla", name: "Tesla",
            authorizeURL:
                "https://oauth.raycast.com/v1/authorize/iJYj_0c8sxOGHvexNi0qXCRaBHscvub2yLI7kZMyK4Ky2u5iV3xTuVTNE3LW-0ex07VjFpdLEVEoLB1yD2XlGoVYz8ph_4UjUroi4j4MNVYmvTQeIOZC5HZqR-FFWYliFhI",
            tokenURL:
                "https://oauth.raycast.com/v1/token/p7q14_mMGdFpROFDg19bzNg2blC7PT5i4a6ngcQP9vOfa6PV5udRzR_zvXopGW1U1u9IVw-BweEiW1oOV7L9yOd8buGsNoPdJMf4wyhZ2A6fStxe1I66z_FOpZwt4Q",
            refreshURL:
                "https://oauth.raycast.com/v1/refresh-token/xG23f3tmUA9zNOewrzh164GX_4cZ1FzUAmVD1kt9YLigM2OcdKeMPh78YwDZKuXNPM3ipD-BDuQXC_6mo7qPe7MPpX4u701JXxhPoAjx9yjLxf-_3IStAzrpwVHSzA"
        ),
    ]

    /// Atlassian's name, as Settings and the sign-in prompt show it.
    public static let atlassianName = "Atlassian (Jira, Confluence)"

    /// Raycast's proxy at `<host>.oauth.raycast.com`, as `OAuthService` uses it by default for GitHub, Linear, Slack
    /// and Asana, and store extensions set it for Jira, Zoom, Notion, WHOOP and Miro, sent to the relay's `relay`
    /// provider.
    private static func raycastProxy(_ host: String, _ name: String, relay: String? = nil) -> OAuthProvider {
        let base = "https://\(host).oauth.raycast.com"
        return OAuthProvider(
            id: relay ?? host, name: name, authorizeURL: "\(base)/authorize", tokenURL: "\(base)/token",
            refreshURL: "\(base)/refresh-token")
    }

    /// The relay's names before they changed: a sign-in stored with `relayProvider: "jira"` (the relay's Atlassian
    /// provider until v0.3.0) counts as Atlassian's.
    static let renamedRelayProviders = ["jira": "atlassian"]

    /// A stored sign-in's relay provider by its current name.
    public static func currentRelayProvider(_ stored: String) -> String {
        renamedRelayProviders[stored] ?? stored
    }

    /// The provider whose default authorize URL this is, exactly; nil for anything else.
    public static func provider(authorizing endpoint: String) -> OAuthProvider? {
        all.first { $0.authorizeURL == endpoint }
    }

    /// Raycast's proxy hosts. With sign-in off, the worker refuses requests to them rather than send one.
    public static var raycastHosts: [String] {
        all.compactMap { URL(string: $0.tokenURL)?.host }.filter { $0.hasSuffix(".oauth.raycast.com") }
    }

    /// The environment variable that hands this table to the extension host, whose workers rewrite `fetch` with it.
    public static let environmentKey = "FUDGE_OAUTH_PROVIDERS"

    /// The table as JSON, for `environmentKey`.
    public static var environmentValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(all)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Raycast's domains (SPEC-132 §2): each, and every host under it, is Raycast's. The one definition, which
    /// `oauth.prepare` refuses and the worker refuses token and refresh grants to (`isRaycastDomainHost` in
    /// `oauth-fetch.ts`, handed this list in `raycastDomainsEnvironmentKey`).
    public static let raycastDomains = ["raycast.com"]

    /// Whether `host` is one of Raycast's: a domain in `raycastDomains` or a host under it, ignoring case and trailing
    /// dots. Raycast's sign-in proxies and raycast.com's own sign-in all are.
    public static func isRaycastDomainHost(_ host: String) -> Bool {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return raycastDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The environment variable that hands `raycastDomains` to the extension host.
    public static let raycastDomainsEnvironmentKey = "FUDGE_RAYCAST_DOMAINS"

    /// `raycastDomains` as JSON, for `raycastDomainsEnvironmentKey`.
    public static var raycastDomainsEnvironmentValue: String {
        let data = (try? JSONEncoder().encode(raycastDomains)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The hosts of the table's own authorize URLs that aren't Raycast's (`accounts.google.com`, `auth.atlassian.com`,
    /// `zoom.us`), lowercased: an endpoint there that isn't the table's exact URL is refused (SPEC-132 §2 step 2a),
    /// since the worker can't tell its token exchange from the relay sign-in's.
    public static var ownAuthorizeHosts: Set<String> {
        Set(all.compactMap { URL(string: $0.authorizeURL)?.host?.lowercased() }.filter { !isRaycastDomainHost($0) })
    }

    /// Whether `host` is one of `ownAuthorizeHosts`, ignoring case and trailing dots.
    public static func isOwnAuthorizeHost(_ host: String) -> Bool {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return ownAuthorizeHosts.contains(host)
    }
}

/// The relay extensions sign in through (`signInServer` in `settings.json`): off, Fudge's own, or the user's.
public enum SignInServer: Sendable, Equatable {
    case off
    case fudge
    case custom(URL)

    /// What the server is for, under the Sign-in page's choice and onboarding's.
    public static let explanation = "Extensions sign in to services through this server."

    /// Fudge's sign-in server.
    public static let fudgeURL = URL(string: "https://fudge-oauth.rackofpain.net")!

    /// The relay's address; nil when off.
    public var url: URL? {
        switch self {
        case .off: nil
        case .fudge: Self.fudgeURL
        case .custom(let url): url
        }
    }

    /// The relay's host, as the consent sheet names it.
    public var host: String? { url?.host }

    /// `<server>/<provider>/<endpoint>`, for `authorize`, `token` or `refresh-token`.
    public func endpoint(_ provider: OAuthProvider, _ name: String) -> String? {
        guard let url else { return nil }
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(provider.id)/\(name)"
    }

    /// The value saved in `settings.json`: `"fudge"` or the URL.
    public var settingsValue: String? {
        switch self {
        case .off: nil
        case .fudge: "fudge"
        case .custom(let url): url.absoluteString
        }
    }

    /// Reads a saved value. Anything that isn't `"fudge"` or a valid server URL is off.
    public init(settingsValue: String?) {
        guard let value = settingsValue else {
            self = .off
            return
        }
        if value == "fudge" {
            self = .fudge
        } else if case .success(let url) = Self.validate(value) {
            self = .custom(url)
        } else {
            self = .off
        }
    }

    /// Why a typed server address can't be used.
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case notAURL
        /// Only `https://`, or `http://` on `localhost` or `127.0.0.1`.
        case insecure
        /// User info, a query or a fragment.
        case extraParts

        public var message: String {
            switch self {
            case .empty: "Enter the server's address."
            case .notAURL: "Enter a URL, like https://sign-in.example.com."
            case .insecure: "Use https://, or http:// on localhost or 127.0.0.1."
            case .extraParts: "Leave out the user name, password, query and fragment."
            }
        }
    }

    /// Checks a typed address for "Your own server…": an `https://` URL with a host, or `http://` on `localhost` or
    /// `127.0.0.1` for testing, with no user info, query or fragment. Surrounding whitespace is ignored.
    ///
    /// The address is returned as the worker's `new URL()` writes it, since a sign-in's authorize URL is compared with
    /// what the worker sends back (`PreparedSignIn.state(ofAuthorizeURL:)`): the scheme and host in lowercase, no
    /// default port, and the path's dot segments resolved. A host that parser would rewrite in other ways (non-ASCII,
    /// percent-encoded, IPv6, or an IPv4 address written other than as four decimal numbers) isn't accepted.
    public static func validate(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            let host = components.percentEncodedHost.flatMap(canonicalHost)
        else { return .failure(.notAURL) }
        switch scheme {
        case "https": break
        case "http" where ["localhost", "127.0.0.1"].contains(host): break
        case "http": return .failure(.insecure)
        default: return .failure(.notAURL)
        }
        if components.user != nil || components.password != nil || components.query != nil
            || components.fragment != nil
        {
            return .failure(.extraParts)
        }
        var authority = host
        if let port = components.port {
            guard (0...65535).contains(port) else { return .failure(.notAURL) }
            if port != (scheme == "https" ? 443 : 80) { authority += ":\(port)" }
        }
        let path = resolvingDotSegments(components.percentEncodedPath)
        guard let url = URL(string: "\(scheme)://\(authority)\(path)") else { return .failure(.notAURL) }
        return .success(url)
    }

    private static let hostScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")

    /// A host in lowercase, when the URL parser would only change its letter case: an ASCII name, or an IPv4 address
    /// as four decimal numbers. Nil for anything else.
    static func canonicalHost(_ host: String) -> String? {
        let lowered = host.lowercased()
        guard !lowered.isEmpty, lowered.unicodeScalars.allSatisfy(hostScalars.contains) else { return nil }
        // A name whose last label is a number (decimal, or hex after "0x") is read as an IPv4 address, in any of
        // several notations, so only the one it's written back in is kept.
        var labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        guard let last = labels.last else { return nil }
        let isNumber =
            (!last.isEmpty && last.allSatisfy { $0.isASCII && $0.isNumber })
            || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        guard isNumber else { return lowered }
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        let canonical =
            octets.count == 4
            && octets.allSatisfy { octet in
                guard let value = Int(octet), (0...255).contains(value) else { return false }
                return String(value) == octet
            }
        return canonical ? lowered : nil
    }

    /// A path with its `.` and `..` segments resolved as the URL parser does, `%2e` counting as a dot.
    static func resolvingDotSegments(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var resolved: [Substring] = []
        for (index, segment) in zip(segments.indices, segments) {
            let isLast = index == segments.indices.last
            switch segment.lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !resolved.isEmpty { resolved.removeLast() }
                if isLast { resolved.append("") }
            case ".", "%2e":
                if isLast { resolved.append("") }
            default:
                resolved.append(segment)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// The sheet before a server is saved.
    public enum Consent {
        public static func title(host: String) -> String { "Extensions will sign in through \(host)." }
        public static let confirm = "Continue"
        public static let cancel = "Cancel"
    }

    /// The sheet before a change that signs out of everything.
    public enum Change {
        public static let title = "Sign out of everything?"
        public static let message = "Changing the sign-in server signs every extension out."
        public static let confirm = "Change Server"
        public static let cancel = "Cancel"
    }
}

extension FudgeSettings {
    /// The sign-in server in use: off unless it was chosen through the consent sheet, which records the date, so a
    /// hand-set value counts as off.
    public var signIn: SignInServer {
        guard signInServerConsentAt.flatMap(ISO8601DateFormatter().date(from:)) != nil else { return .off }
        return SignInServer(settingsValue: signInServer)
    }

    /// Chooses a server, as the consent sheet's Continue does; off removes both keys.
    public mutating func setSignIn(_ server: SignInServer, now: Date) {
        signInServer = server.settingsValue
        signInServerConsentAt = server == .off ? nil : ISO8601DateFormatter().string(from: now)
    }
}

/// What the loopback listener makes of one request (SPEC-056 §2).
public enum OAuthCallback: Equatable, Sendable {
    /// Not the callback: another path or method. Answered with a 404, and the sign-in keeps waiting.
    case notFound
    /// The provider's code, with the sign-in's own `state`.
    case code(String)
    /// The provider (or the relay) refused, with its `error` and `error_description`.
    case error(String, description: String?)
    /// The callback's `state` isn't this sign-in's, or it has neither a code nor an error. Answered with a 400, and
    /// the sign-in keeps waiting: a stray request mustn't cancel it.
    case invalid

    /// Whether the callback ends the sign-in's wait: only a code or an error with this sign-in's `state`.
    public var endsWait: Bool {
        switch self {
        case .code, .error: true
        case .notFound, .invalid: false
        }
    }

    /// Reads an HTTP request's first line (`GET /oauth/callback/<random>?code=…&state=… HTTP/1.1`). Only a `GET` on
    /// exactly `path` is the callback; its `state` must equal `state`.
    public static func read(requestLine: String, path: String, state: String) -> OAuthCallback {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
            let components = URLComponents(string: String(parts[1])), components.scheme == nil,
            components.host == nil, components.percentEncodedPath == path
        else { return .notFound }
        return read(query: components.queryItems ?? [], state: state)
    }

    /// Reads a callback's query: its first `state`, `code`, `error` and `error_description`. Only this sign-in's
    /// `state` (compared in constant time) with a code or an error ends the wait; anything else is `invalid`. The
    /// loopback's request line, Raycast's return link and a pasted address are all read this way (SPEC-132 §3.2).
    static func read(query items: [URLQueryItem], state: String) -> OAuthCallback {
        var values: [String: String] = [:]
        for item in items where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard let given = values["state"], constantTimeEqual(given, state) else { return .invalid }
        if let error = values["error"], !error.isEmpty {
            return .error(error, description: values["error_description"].flatMap { $0.isEmpty ? nil : $0 })
        }
        if let code = values["code"], !code.isEmpty { return .code(code) }
        return .invalid
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A random URL-safe string with `bytes` of randomness, for the callback's path.
    public static func randomToken(bytes: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The page the browser shows once the callback is read.
    public static func page(signedIn: Bool) -> String {
        let text = signedIn ? "Signed in. You can close this tab." : "Sign-in didn't finish. You can close this tab."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Fudge</title>\
            <style>body{font:16px -apple-system,sans-serif;margin:4em;text-align:center}</style></head>\
            <body><p>\(text)</p></body></html>
            """
    }
}

/// A stored sign-in: Raycast's `TokenSet`, plus the provider's name for the Settings page.
public struct StoredTokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresIn: Double?
    public var scope: String?
    /// ISO 8601.
    public var updatedAt: String
    public var providerName: String?
    /// The `OAuthProviders` id this sign-in went through the relay for. The worker sends a provider's own token URL
    /// (Google's, Atlassian's, Zoom's) to the relay only for an extension with such a sign-in.
    public var relayProvider: String?

    public init(
        accessToken: String, refreshToken: String? = nil, idToken: String? = nil, expiresIn: Double? = nil,
        scope: String? = nil, updatedAt: String, providerName: String? = nil, relayProvider: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.updatedAt = updatedAt
        self.providerName = providerName
        self.relayProvider = relayProvider
    }
}

/// Where tokens are kept: the Keychain in the app, a dictionary in tests and snapshot runs. Each item is one
/// account's data under Fudge's sign-in service.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}

/// One row of Settings → Sign-in.
public struct SignInEntry: Equatable, Sendable, Identifiable {
    public var extensionName: String
    public var providerID: String
    public var providerName: String
    public var updatedAt: Date?
    public var id: String { OAuthTokenStore.account(extension: extensionName, provider: providerID) }
}

/// The sign-ins Fudge keeps: one item per extension and `providerId`, account `<extension>/<providerId>`, holding a
/// JSON `StoredTokenSet`.
public struct OAuthTokenStore: Sendable {
    /// The Keychain service of every item.
    public static let service = "io.github.jakeobsen.fudge.oauth"

    public let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The extension or provider id can't name an item.
        case invalidName
        /// `setTokens` without an access token.
        case invalidTokens
        case unknownCall

        public var description: String {
            switch self {
            case .invalidName: "A sign-in's provider id needs 1 to 64 characters, without a slash."
            case .invalidTokens: "setTokens needs an access token."
            case .unknownCall: "Fudge doesn't know this sign-in call."
            }
        }
    }

    public static func account(extension extensionName: String, provider: String) -> String {
        "\(extensionName)/\(provider)"
    }

    /// A provider id from an extension: 1–64 characters, none of them `/` or a control character.
    static func isValid(provider: String) -> Bool {
        (1...64).contains(provider.count) && !provider.contains("/")
            && !provider.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func checkedAccount(_ extensionName: String, _ provider: String) throws -> String {
        guard !extensionName.isEmpty, !extensionName.contains("/"), Self.isValid(provider: provider) else {
            throw Failure.invalidName
        }
        return Self.account(extension: extensionName, provider: provider)
    }

    public func tokens(extension extensionName: String, provider: String) throws -> StoredTokenSet? {
        guard let data = try secrets.read(account: checkedAccount(extensionName, provider)) else { return nil }
        return try? JSONDecoder().decode(StoredTokenSet.self, from: data)
    }

    public func save(_ tokens: StoredTokenSet, extension extensionName: String, provider: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try secrets.write(encoder.encode(tokens), account: checkedAccount(extensionName, provider))
    }

    public func remove(extension extensionName: String, provider: String) throws {
        try secrets.delete(account: checkedAccount(extensionName, provider))
    }

    /// Every stored sign-in, by extension then provider. An item that doesn't read is listed by its account, so it
    /// can still be signed out of.
    public func entries() throws -> [SignInEntry] {
        try secrets.accounts().compactMap { account -> SignInEntry? in
            guard let slash = account.firstIndex(of: "/") else { return nil }
            let extensionName = String(account[..<slash])
            let provider = String(account[account.index(after: slash)...])
            let stored = (try? secrets.read(account: account)).flatMap {
                try? JSONDecoder().decode(StoredTokenSet.self, from: $0)
            }
            return SignInEntry(
                extensionName: extensionName, providerID: provider,
                providerName: stored?.providerName ?? provider,
                updatedAt: stored.flatMap { ISO8601DateFormatter().date(from: $0.updatedAt) })
        }
        .sorted { ($0.extensionName, $0.providerID) < ($1.extensionName, $1.providerID) }
    }

    /// Signs out of everything, as changing the server does.
    public func removeAll() throws {
        for account in try secrets.accounts() { try secrets.delete(account: account) }
    }
}

/// A `SecretStore` in memory, for tests and snapshot runs.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    public init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    public func read(account: String) throws -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { items[account] = nil } }
    public func accounts() throws -> [String] { lock.withLock { items.keys.sorted() } }
}

/// Why a sign-in didn't happen, as the extension's call is rejected.
public enum SignInRefusal: Error, Equatable, Sendable {
    case off
    case unknownProvider(String)
    /// The call came from a command the user isn't using (SPEC-045).
    case background
    /// Another sign-in is on screen.
    case busy
    /// `authorize` without `authorizationRequest` first, or with a URL that isn't the request's.
    case notPrepared
    case cancelled
    case timedOut
    /// The provider or the relay refused: `error`, `error_description`.
    case refused(provider: String, error: String, description: String?)
    /// The callback's state didn't match, or it had no code.
    case browser

    public var message: String {
        switch self {
        case .off: "Sign-in is off. " + SignInNotice.offText(extensionTitle: nil)
        case .unknownProvider(let name): "Fudge can't sign in to \(name.isEmpty ? "this service" : name) yet."
        case .background: "Sign in from Fudge to continue."
        case .busy: "Another sign-in is in progress. Finish or cancel it first."
        case .notPrepared: "This sign-in request didn't come from Fudge. Try again."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out after 5 minutes. Try again."
        case .refused(let provider, let error, let description):
            "\(provider) didn't sign you in: \(description ?? error)"
        case .browser: "Fudge couldn't open the browser."
        }
    }

    /// The notice the command shows for this refusal instead of a failure (SPEC-095), sent with it as `rpcResult`'s
    /// `notice`; nil for the refusals that are failures.
    public var notice: SignInNotice.Kind? {
        switch self {
        case .off: .off
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .refused: .refused
        case .unknownProvider, .background, .busy, .notPrepared, .browser: nil
        }
    }
}

/// A sign-in request the app has made ready (`oauth.prepare`): where it goes, its authorize URL and its redirect.
public struct PreparedSignIn: Equatable, Sendable {
    /// Where a sign-in goes (SPEC-132 §2).
    public enum Path: Equatable, Sendable {
        /// Through the relay, for one of `OAuthProviders`: the loopback listener takes the code.
        case relay(OAuthProvider)
        /// Straight to the extension's own OAuth app, coming back through Raycast's return address for the method:
        /// a `raycast://oauth` link, or a pasted address (Web).
        case direct(OAuthRedirectMethod)
    }

    public var path: Path
    public var authorizeURL: String
    public var redirectURI: String

    public init(provider: OAuthProvider, authorizeURL: String, redirectURI: String) {
        self.init(path: .relay(provider), authorizeURL: authorizeURL, redirectURI: redirectURI)
    }

    public init(path: Path, authorizeURL: String, redirectURI: String) {
        self.path = path
        self.authorizeURL = authorizeURL
        self.redirectURI = redirectURI
    }

    /// The relay's provider; nil on the direct path, which marks nothing pending and stores no `relayProvider`.
    public var provider: OAuthProvider? {
        if case .relay(let provider) = path { provider } else { nil }
    }

    /// The direct path's method; nil on the relay path.
    public var directMethod: OAuthRedirectMethod? {
        if case .direct(let method) = path { method } else { nil }
    }

    /// Maps `endpoint` (the extension's authorize URL) to a provider and the relay's authorize URL; refuses while
    /// sign-in is off and for any endpoint not in `OAuthProviders`. The redirect is filled in once the listener is up.
    public static func provider(
        for endpoint: String, providerName: String, server: SignInServer
    ) -> Result<(OAuthProvider, String), SignInRefusal> {
        guard server != .off else { return .failure(.off) }
        guard let provider = OAuthProviders.provider(authorizing: endpoint),
            let authorize = server.endpoint(provider, "authorize")
        else { return .failure(.unknownProvider(providerName)) }
        return .success((provider, authorize))
    }

    /// What `oauth.prepare` decides (SPEC-132 §2).
    public enum Route: Equatable, Sendable {
        /// The relay path: the provider and the relay's authorize URL; the loopback listener gives the redirect.
        case relay(OAuthProvider, authorizeURL: String)
        /// The direct path: the endpoint as the extension gave it, and Raycast's redirect for the method.
        case direct(OAuthRedirectMethod, authorizeURL: String, redirectURI: String)
    }

    /// Where a sign-in for `endpoint` goes, in this order (SPEC-132 §2):
    /// 1. an endpoint in `OAuthProviders` takes the relay path, exactly as before (`provider(for:providerName:server:)`);
    /// 2. one on Raycast's hosts (`OAuthProviders.isRaycastDomainHost`) is refused as before;
    /// 2a. so is one on a table entry's own authorize host that isn't the table's exact URL
    ///    (`OAuthProviders.isOwnAuthorizeHost`), since the worker can't tell its token exchange from the relay's;
    /// 3. any other `https` endpoint with a host and no user info takes the direct path, for the Web, App and AppURI
    ///    methods only, while **Extensions with their own sign-in** is on (`ownAppSignIn`);
    /// 4. anything else is refused.
    /// Nothing here depends on a particular extension (D-83).
    public static func route(
        for endpoint: String, providerName: String, redirectMethod: String, server: SignInServer, ownAppSignIn: Bool
    ) -> Result<Route, SignInRefusal> {
        if OAuthProviders.provider(authorizing: endpoint) != nil {
            return provider(for: endpoint, providerName: providerName, server: server).map {
                .relay($0.0, authorizeURL: $0.1)
            }
        }
        guard let components = URLComponents(string: endpoint) else { return .failure(.unknownProvider(providerName)) }
        if let host = components.host,
            OAuthProviders.isRaycastDomainHost(host) || OAuthProviders.isOwnAuthorizeHost(host)
        {
            // Steps 2 and 2a: the same refusal as before the direct path existed.
            return .failure(server == .off ? .off : .unknownProvider(providerName))
        }
        guard isDirectURL(components), let method = OAuthRedirectMethod(rawValue: redirectMethod) else {
            return .failure(.unknownProvider(providerName))
        }
        guard ownAppSignIn else { return .failure(.off) }
        return .success(.direct(method, authorizeURL: endpoint, redirectURI: method.raycastRedirectURI))
    }

    /// Whether a URL may be a direct sign-in's (SPEC-132 §2 step 3, §4): `https`, with a host and no user info, on
    /// neither Raycast's hosts nor a table entry's own authorize host.
    static func isDirectURL(_ components: URLComponents) -> Bool {
        guard components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil
        else { return false }
        return !OAuthProviders.isRaycastDomainHost(host) && !OAuthProviders.isOwnAuthorizeHost(host)
    }

    /// The `state` of a URL the extension asks to open, or nil when it may not be opened.
    ///
    /// On the relay path it must be the relay's authorize URL this request names, with this request's redirect and a
    /// `state`. On the direct path it's any `https` URL with a host and no user info, on neither Raycast's hosts nor a
    /// table entry's own authorize host (`isDirectURL`), whose `state` is this request's
    /// (`given`, the `state` the extension sends with it, when it sends one): some extensions build the URL themselves
    /// or override the redirect, so its host, path and redirect may differ from the endpoint's.
    public func state(ofAuthorizeURL url: String, given: String? = nil) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let items = components.queryItems ?? []
        let state = items.first(where: { $0.name == "state" })?.value ?? ""
        switch path {
        case .relay:
            guard let expected = URLComponents(string: authorizeURL),
                components.scheme == expected.scheme, components.host == expected.host,
                components.port == expected.port, components.path == expected.path,
                items.first(where: { $0.name == "redirect_uri" })?.value == redirectURI, !state.isEmpty
            else { return nil }
            return state
        case .direct:
            guard Self.isDirectURL(components), !state.isEmpty else { return nil }
            if let given, !given.isEmpty, !OAuthCallback.constantTimeEqual(given, state) { return nil }
            return state
        }
    }
}

/// Which loopback listener each sign-in uses: every session's latest prepared request, and the one the "Sign in to …"
/// prompt shows. The prompt takes its request when it's shown, so a request the session prepares meanwhile never
/// takes its place: Esc, the command going away and the end of the sign-in all reach the listener being waited on.
///
/// It also says which relay sign-ins are pending (`pending(of:)`, for `SignInCalls`): prepared, shown, or signed in
/// with the token exchange still to come. One that ends without a code (Esc, an error, the timeout, a request that's
/// replaced or expires) is pending no more.
public struct SignInRequests<Listener: AnyObject> {
    public typealias Request = (request: PreparedSignIn, listener: Listener)

    private var prepared: [String: Request] = [:]
    /// The request the prompt shows, with its session.
    public private(set) var shown: (session: String, request: Request)?
    /// The providers each session signed in to, whose tokens the extension exchanges and stores next.
    private var signedIn: [String: Set<String>] = [:]

    public init() {}

    /// Keeps `request` as `session`'s latest. Returns the listener of an earlier one nothing used, to close.
    public mutating func prepare(_ request: Request, for session: String) -> Listener? {
        defer { prepared[session] = request }
        return prepared[session]?.listener
    }

    /// `session`'s latest prepared request, not yet shown.
    public func preparedRequest(of session: String) -> Request? { prepared[session] }

    /// The prompt takes `session`'s prepared request; nil when there's none, or a prompt is already up.
    public mutating func show(_ session: String) -> Request? {
        guard shown == nil, let request = prepared.removeValue(forKey: session) else { return nil }
        shown = (session, request)
        return request
    }

    /// The listener the prompt waits on, which Esc cancels.
    public var waitedOn: Listener? { shown?.request.listener }

    /// The sign-in using `listener` is over, with a code (`signedIn`) or without one. True when it was the prompt's,
    /// which is then gone.
    public mutating func finish(_ listener: Listener, signedIn code: Bool) -> Bool {
        guard let shown, shown.request.listener === listener else { return false }
        if code, let provider = shown.request.request.provider {
            signedIn[shown.session, default: []].insert(provider.id)
        }
        self.shown = nil
        return true
    }

    /// The providers `session` has a relay sign-in pending for: its prepared request's, the prompt's when it's
    /// `session`'s, and those it signed in to. A direct sign-in (SPEC-132) is never pending: the fetch rewrite leaves
    /// its token exchange alone.
    public func pending(of session: String) -> Set<String> {
        var providers = signedIn[session] ?? []
        if let provider = prepared[session]?.request.provider { providers.insert(provider.id) }
        if let shown, shown.session == session, let provider = shown.request.request.provider {
            providers.insert(provider.id)
        }
        return providers
    }

    /// A request unused after its time: true, and dropped, when `listener` is still `session`'s prepared one.
    public mutating func expire(_ listener: Listener, of session: String) -> Bool {
        guard prepared[session]?.listener === listener else { return false }
        prepared[session] = nil
        return true
    }

    /// `session` is going away: its unused request is dropped, to close, and the prompt's listener, when the prompt
    /// is its, is returned to cancel. The prompt stays until its sign-in finishes.
    public mutating func end(_ session: String) -> (unused: Listener?, waitedOn: Listener?) {
        signedIn[session] = nil
        let unused = prepared.removeValue(forKey: session)?.listener
        return (unused, shown?.session == session ? shown?.request.listener : nil)
    }
}

/// A `data:` URL's bytes, for images such as `@raycast/utils`' provider icons (`data:image/svg+xml,…`).
public enum DataURL {
    /// The media type and the bytes; nil for anything but a `data:` URL whose media type is an image, or bytes past
    /// `limit`.
    public static func image(_ text: String, limit: Int = 1024 * 1024) -> (type: String, data: Data)? {
        guard text.lowercased().hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        var parameters = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let type = parameters.isEmpty ? "" : parameters.removeFirst()
        guard type.hasPrefix("image/") else { return nil }
        let payload = String(text[text.index(after: comma)...])
        let data: Data?
        if parameters.contains("base64") {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, data.count <= limit else { return nil }
        return (type, data)
    }
}

extension OAuthTokenStore {
    /// A stored sign-in as the worker gets it.
    public static func json(_ tokens: StoredTokenSet) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tokens))) ?? .null
    }

    /// The tokens a worker sends to `setTokens`; nil without an access token or an `updatedAt`.
    public static func tokenSet(_ json: JSONValue) -> StoredTokenSet? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(StoredTokenSet.self, from: data)
    }
}

/// The worker's `oauth.tokens.*` and `oauth.server` calls, for one extension: the calling session's, never one named in
/// the parameters. `pending` holds the providers this session has prepared a relay sign-in for.
public struct SignInCalls: Sendable {
    public let store: OAuthTokenStore
    public let extensionName: String
    public let pending: Set<String>

    public init(store: OAuthTokenStore, extensionName: String, pending: Set<String>) {
        self.store = store
        self.extensionName = extensionName
        self.pending = pending
    }

    public func answer(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let values: [String: JSONValue] = if case .object(let object) = params { object } else { [:] }
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        let provider = string("providerId") ?? ""
        switch method {
        case "oauth.tokens.get":
            return try store.tokens(extension: extensionName, provider: provider).map(OAuthTokenStore.json) ?? .null
        case "oauth.tokens.set":
            guard var tokens = values["tokens"].flatMap(OAuthTokenStore.tokenSet) else {
                throw OAuthTokenStore.Failure.invalidTokens
            }
            // Only a relay sign-in this session prepared marks the tokens; a refresh keeps the mark they had.
            let existing = try store.tokens(extension: extensionName, provider: provider)
            tokens.relayProvider =
                tokens.relayProvider.flatMap { pending.contains($0) ? $0 : nil }
                ?? existing?.relayProvider
            try store.save(tokens, extension: extensionName, provider: provider)
            return .null
        case "oauth.tokens.remove":
            try store.remove(extension: extensionName, provider: provider)
            return .null
        default:
            throw OAuthTokenStore.Failure.unknownCall
        }
    }

    /// Whether this extension has a relay sign-in for `provider` (an `OAuthProviders` id): one this session prepared,
    /// or one it stored.
    public func hasRelaySignIn(provider: String) throws -> Bool {
        if pending.contains(provider) { return true }
        let prefix = OAuthTokenStore.account(extension: extensionName, provider: "")
        return try store.secrets.accounts().contains { account in
            guard account.hasPrefix(prefix), let data = try? store.secrets.read(account: account),
                let tokens = try? JSONDecoder().decode(StoredTokenSet.self, from: data)
            else { return false }
            return tokens.relayProvider.map(OAuthProviders.currentRelayProvider) == provider
        }
    }
}
